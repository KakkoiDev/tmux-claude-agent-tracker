#!/usr/bin/env bash
set -euo pipefail

# ── source helpers ───────────────────────────────────────────────────

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPTS_DIR/helpers.sh"

# Config loaded lazily — only when render or sound is needed
TRACKER_DIR="${TRACKER_DIR:-$HOME/.tmux-claude-agent-tracker}"
DB="${DB:-$TRACKER_DIR/tracker.db}"
CACHE="${CACHE:-$TRACKER_DIR/status_cache}"

sql() { printf '.timeout 100\n%s\n' "$*" | sqlite3 "$DB"; }
sql_sep() { local s="$1"; shift; printf '.timeout 100\n%s\n' "$*" | sqlite3 -separator "$s" "$DB"; }
sql_esc() { local q="'"; printf '%s' "${1//$q/$q$q}"; }

# Fast JSON value extraction — replaces jq for simple key lookups
_json_val() {
    local _t="${1#*\"$2\":\"}"
    [[ "$_t" == "$1" ]] && return
    printf '%s' "${_t%%\"*}"
}

# Render SQL fragment — used by combined hook+render and standalone _render_cache
_RENDER_SQL="SELECT
    COALESCE(SUM(CASE WHEN status='working' THEN 1 ELSE 0 END),0) || '|' ||
    COALESCE(SUM(CASE WHEN status='blocked' THEN 1 ELSE 0 END),0) || '|' ||
    COALESCE(SUM(CASE WHEN status='idle' THEN 1 ELSE 0 END),0) || '|' ||
    COALESCE((SELECT (unixepoch()-MIN(updated_at))/60 FROM sessions WHERE status='blocked' AND (agent_type IS NULL OR agent_type='')),0)
    FROM sessions WHERE (agent_type IS NULL OR agent_type='')"

_play_sound() {
    case "$(uname)" in
        Darwin) afplay /System/Library/Sounds/Glass.aiff ;;
        *)      paplay /usr/share/sounds/freedesktop/stereo/complete.oga 2>/dev/null \
                || aplay /usr/share/sounds/freedesktop/stereo/complete.oga 2>/dev/null \
                || true ;;
    esac
}

# ── init ──────────────────────────────────────────────────────────────

cmd_init() {
    mkdir -p "$TRACKER_DIR"
    sqlite3 "$DB" <<'SQL'
PRAGMA journal_mode=WAL;
PRAGMA busy_timeout=100;

CREATE TABLE IF NOT EXISTS sessions (
    session_id    TEXT PRIMARY KEY,
    status        TEXT NOT NULL DEFAULT 'working'
        CHECK(status IN ('working', 'blocked', 'idle')),
    cwd           TEXT NOT NULL,
    project_name  TEXT NOT NULL,
    git_branch    TEXT,
    prompt_summary TEXT,
    agent_type    TEXT,
    tmux_pane     TEXT,
    tmux_target   TEXT,
    started_at    INTEGER NOT NULL DEFAULT (unixepoch()),
    updated_at    INTEGER NOT NULL DEFAULT (unixepoch())
);
SQL
    echo "Initialized: $DB"
}

# ── hook ──────────────────────────────────────────────────────────────

cmd_hook() {
    [[ -f "$DB" ]] || return 0
    local event="$1"
    local json
    read -r json || true
    [[ -z "$json" ]] && json='{}'

    local sid
    sid=$(_json_val "$json" "session_id")
    [[ -z "$sid" ]] && return 0
    sid=$(sql_esc "$sid")

    # _ensure_session only for hooks that may create sessions.
    # Hot-path hooks (PostToolUse, Notification, Stop, TeammateIdle) skip this
    # — their UPDATEs are no-ops if session doesn't exist yet.
    case "$event" in
        SessionStart|UserPromptSubmit|SubagentStart)
            _ensure_session "$sid" "$json" ;;
    esac

    local __changed=1 __render=""
    case "$event" in
        SessionStart)     _hook_session_start "$sid" "$json" ;;
        UserPromptSubmit) _hook_prompt "$sid" "$json" ;;
        PostToolUse)      _hook_post_tool "$sid" ;;
        Stop)             _hook_stop "$sid" "$json" ;;
        Notification)     _hook_notification "$sid" ;;
        SessionEnd)       sql "DELETE FROM sessions WHERE session_id='$sid';" ;;
        SubagentStart)    _hook_subagent_start "$sid" "$json" ;;
        SubagentStop)     return 0 ;;  # cleanup deferred to _hook_stop
        TeammateIdle)     _hook_teammate_idle "$json" ;;
        *) return 0 ;;
    esac

    # Reap stale sessions on events that create/wake sessions
    case "$event" in
        SessionStart|UserPromptSubmit)
            _reap_dead 2>/dev/null || true ;;
    esac

    if [[ -n "$__render" ]]; then
        # Fast path: render data already fetched in same sqlite3 call
        _load_config_fast
        _write_cache "$__render" 2>/dev/null || _render_cache 2>/dev/null || true
        tmux refresh-client -S 2>/dev/null || true
    elif [[ "$__changed" -eq 1 ]]; then
        _render_cache 2>/dev/null || true
        tmux refresh-client -S 2>/dev/null || true
    fi

    # Sound after render — config already loaded
    if [[ "$event" == "Notification" && -n "$__render" && "${SOUND:-0}" == "1" ]]; then
        _play_sound &
    fi
}

_ensure_session() {
    local sid="$1" json="${2:-}"

    # Fast path: session already registered with pane info — skip git/tmux overhead
    local existing
    existing=$(sql "SELECT 1 FROM sessions WHERE session_id='$sid' AND tmux_pane != '' LIMIT 1;")
    [[ -n "$existing" ]] && return 0

    local cwd project branch pane target
    cwd=$(_json_val "$json" "cwd")
    [[ -z "$cwd" ]] && cwd="${PWD}"
    project=$(basename "$cwd")
    branch=$(git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
    pane="${TMUX_PANE:-}"
    target=""
    if [[ -n "$pane" ]]; then
        target=$(tmux display-message -t "$pane" \
            -p '#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null || true)
    fi

    # One Claude per pane — evict stale *main* sessions on the same pane.
    # Preserve subagent entries (they have agent_type set) so idle counts stay accurate.
    # Atomic: DELETE + INSERT in one sqlite3 process to prevent render seeing N-1 sessions.
    if [[ -n "$pane" ]]; then
        sql "DELETE FROM sessions WHERE tmux_pane='$(sql_esc "$pane")' AND session_id!='$sid'
             AND (agent_type IS NULL OR agent_type='');
             INSERT OR IGNORE INTO sessions
             (session_id, status, cwd, project_name, git_branch, tmux_pane, tmux_target)
             VALUES ('$sid', 'working',
                     '$(sql_esc "$cwd")', '$(sql_esc "$project")',
                     '$(sql_esc "$branch")', '$(sql_esc "$pane")',
                     '$(sql_esc "$target")');"
    else
        sql "INSERT OR IGNORE INTO sessions
             (session_id, status, cwd, project_name, git_branch, tmux_pane, tmux_target)
             VALUES ('$sid', 'working',
                     '$(sql_esc "$cwd")', '$(sql_esc "$project")',
                     '$(sql_esc "$branch")', '', '');"
    fi

    # Backfill tmux info if missing (session existed but lacked pane data)
    if [[ -n "$pane" ]]; then
        sql "UPDATE sessions SET tmux_pane='$(sql_esc "$pane")',
             tmux_target='$(sql_esc "$target")'
             WHERE session_id='$sid' AND (tmux_pane IS NULL OR tmux_pane='');"
    fi
}

_hook_session_start() {
    local sid="$1" json="$2"
    # _ensure_session already created the row if missing.
    # Only set idle for genuinely new sessions (never received any other hook).
    # Guard: updated_at = started_at means the row was just created by _ensure_session.
    local c
    c=$(sql "UPDATE sessions SET status='idle', updated_at=unixepoch()
         WHERE session_id='$sid' AND status='working'
         AND updated_at = started_at;
         SELECT changes();")
    if [[ "$c" == "0" ]]; then __changed=0; fi
}

_hook_prompt() {
    local sid="$1"
    sql "UPDATE sessions SET status='working', updated_at=unixepoch()
         WHERE session_id='$sid';"
}

# Hot path: UPDATE + render in one sqlite3 call
_hook_post_tool() {
    local sid="$1"
    __render=$(sql "UPDATE sessions SET status='working', updated_at=unixepoch()
         WHERE session_id='$sid' AND status!='working';
         SELECT CASE WHEN changes() = 0 THEN '' ELSE ($_RENDER_SQL) END;")
    if [[ -z "$__render" ]]; then __changed=0; fi
}

_hook_stop() {
    local sid="$1" json="$2"
    # Atomic: clean up subagent sessions on same pane + set idle.
    # Prevents idle count flicker between SubagentStop and Stop.
    sql "DELETE FROM sessions
         WHERE tmux_pane != '' AND tmux_pane IS NOT NULL
           AND tmux_pane = (SELECT tmux_pane FROM sessions WHERE session_id='$sid')
           AND agent_type IS NOT NULL AND agent_type != '';
         UPDATE sessions SET status='idle', updated_at=unixepoch()
         WHERE session_id='$sid';"
}

# Hot path: UPDATE + render in one sqlite3 call
_hook_notification() {
    local sid="$1"
    __render=$(sql "UPDATE sessions SET status='blocked', updated_at=unixepoch()
         WHERE session_id='$sid' AND status = 'working';
         SELECT CASE WHEN changes() = 0 THEN '' ELSE ($_RENDER_SQL) END;")
    if [[ -z "$__render" ]]; then __changed=0; fi
}

_hook_subagent_start() {
    local sid="$1" json="$2"
    local sub_id cwd project branch atype pane target

    sub_id=$(_json_val "$json" "subagent_id")
    [[ -z "$sub_id" ]] && sub_id="$sid"
    sub_id=$(sql_esc "$sub_id")

    cwd=$(_json_val "$json" "cwd")
    [[ -z "$cwd" ]] && cwd="${PWD}"
    project=$(basename "$cwd")
    branch=$(git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
    atype=$(_json_val "$json" "subagent_type")
    [[ -z "$atype" ]] && atype="subagent"

    pane="${TMUX_PANE:-}"
    target=""
    if [[ -n "$pane" ]]; then
        target=$(tmux display-message -t "$pane" \
            -p '#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null || true)
    fi

    sql "INSERT OR REPLACE INTO sessions
         (session_id, status, cwd, project_name, git_branch, agent_type, tmux_pane, tmux_target)
         VALUES ('$sub_id', 'working',
                 '$(sql_esc "$cwd")', '$(sql_esc "$project")',
                 '$(sql_esc "$branch")', '$(sql_esc "$atype")',
                 '$(sql_esc "$pane")', '$(sql_esc "$target")');"
}

_hook_subagent_stop() {
    local json="$1"
    local sub_id
    sub_id=$(_json_val "$json" "subagent_id")
    [[ -z "$sub_id" ]] && sub_id=$(_json_val "$json" "session_id")
    [[ -z "$sub_id" ]] && return 0
    sub_id=$(sql_esc "$sub_id")
    sql "DELETE FROM sessions WHERE session_id='$sub_id';"
}

_hook_teammate_idle() {
    local json="$1"
    local tid
    tid=$(_json_val "$json" "teammate_id")
    [[ -z "$tid" ]] && tid=$(_json_val "$json" "session_id")
    [[ -z "$tid" ]] && return 0
    tid=$(sql_esc "$tid")
    sql "UPDATE sessions SET status='idle', updated_at=unixepoch()
         WHERE session_id='$tid';"
}

# ── render cache ──────────────────────────────────────────────────────

# Fast config: source cache file directly, skip date+stat freshness check.
# Full load_config (with freshness) runs on status-bar/menu paths.
_load_config_fast() {
    [[ -n "${COLOR_WORKING:-}" ]] && return 0
    local _cc="$TRACKER_DIR/config_cache"
    if [[ -f "$_cc" ]]; then
        source "$_cc"
    else
        load_config 2>/dev/null || true
    fi
}

# Write formatted cache from pre-fetched "w|b|i|dur" data
_write_cache() {
    local w b i dur
    IFS='|' read -r w b i dur <<< "$1"
    w="${w:-0}"; b="${b:-0}"; i="${i:-0}"; dur="${dur:-0}"
    local result=""
    result+="#[fg=${COLOR_IDLE}]${i}.#[default] "
    result+="#[fg=${COLOR_WORKING}]${w}*#[default] "

    if [[ "$b" -gt 0 ]]; then
        local suffix=""
        if [[ "$dur" -ge 60 ]]; then
            suffix="$((dur / 60))h"
        elif [[ "$dur" -gt 0 ]]; then
            suffix="${dur}m"
        fi
        result+="#[fg=${COLOR_BLOCKED}]${b}!${suffix}#[default]"
    else
        result+="#[fg=${COLOR_BLOCKED}]${b}!#[default]"
    fi

    if [[ -n "${2:-}" ]]; then
        result+=" @${2}"
    fi

    local final="${result% }"
    printf '%s' "$final" > "$CACHE.tmp"
    mv -f "$CACHE.tmp" "$CACHE"
    # Push to tmux option for instant display via #{@claude-tracker-status}
    # (#{@option} is re-evaluated on refresh-client -S, unlike #() which is cached)
    tmux set -gq @claude-tracker-status "$final" 2>/dev/null || true
}

_render_cache() {
    [[ -z "${COLOR_WORKING:-}" ]] && { load_config 2>/dev/null || true; }

    local counts
    counts=$(sql_sep '|' "SELECT
        COALESCE(SUM(CASE WHEN status='working' THEN 1 ELSE 0 END),0),
        COALESCE(SUM(CASE WHEN status='blocked' THEN 1 ELSE 0 END),0),
        COALESCE(SUM(CASE WHEN status='idle' THEN 1 ELSE 0 END),0),
        COALESCE((SELECT (unixepoch()-MIN(updated_at))/60 FROM sessions
                  WHERE status='blocked' AND (agent_type IS NULL OR agent_type='')),0)
        FROM sessions WHERE (agent_type IS NULL OR agent_type='');") || return 0
    [[ -z "$counts" ]] && counts="0|0|0|0"

    local project=""
    if [[ "${SHOW_PROJECT:-0}" == "1" ]]; then
        project=$(sql "SELECT project_name FROM sessions
                       WHERE (agent_type IS NULL OR agent_type='')
                       ORDER BY CASE WHEN status='blocked' THEN 0 ELSE 1 END,
                                updated_at DESC LIMIT 1;" 2>/dev/null || true)
    fi
    _write_cache "$counts" "$project"
}

# ── status-bar ────────────────────────────────────────────────────────

cmd_status_bar() {
    [[ -f "$CACHE" ]] && cat "$CACHE"
}

# ── refresh (periodic, called by #() for blocked timer) ──────────────

cmd_refresh() {
    [[ -f "$DB" ]] || return 0
    _render_cache 2>/dev/null || true
    # No stdout — #() renders empty string; display comes from #{@claude-tracker-status}
}

# ── menu ──────────────────────────────────────────────────────────────

cmd_menu() {
    [[ -f "$DB" ]] || return 0
    [[ -z "${ITEMS_PER_PAGE:-}" ]] && { load_config 2>/dev/null || true; }

    local page="${1:-1}"
    local items_per_page="${ITEMS_PER_PAGE:-10}"

    # Total count
    local total
    total=$(sql "SELECT COUNT(*) FROM sessions;") || total=0
    [[ "$total" -eq 0 ]] && { tmux display-message "No active Claude agents"; return; }

    # Pagination math
    local total_pages=$(( (total + items_per_page - 1) / items_per_page ))
    [[ "$page" -lt 1 ]] && page=1
    [[ "$page" -gt "$total_pages" ]] && page="$total_pages"
    local offset=$(( (page - 1) * items_per_page ))

    local rows
    rows=$(sql_sep '|' "SELECT session_id, status, project_name,
               COALESCE(git_branch,''), COALESCE(tmux_target,'')
        FROM sessions
        ORDER BY CASE status
            WHEN 'blocked' THEN 0 WHEN 'working' THEN 1 ELSE 2
        END, updated_at DESC
        LIMIT $items_per_page OFFSET $offset;") || true

    local title="Claude Agents"
    [[ "$total_pages" -gt 1 ]] && title="Claude Agents ($page/$total_pages)"

    local args=(-T "$title")
    while IFS='|' read -r _sid status project branch target; do
        [[ -z "$_sid" ]] && continue
        local icon label
        case "$status" in
            blocked) icon="!" ;;
            working) icon="*" ;;
            *)       icon="." ;;
        esac

        label="${icon} ${project}"
        [[ -n "$branch" ]] && label+="/${branch}"

        if [[ -n "$target" ]]; then
            args+=("$label" "" "run-shell '$SCRIPTS_DIR/tracker.sh goto ${target}'")
        else
            args+=("$label" "" "")
        fi
    done <<< "$rows"

    # Navigation separator and items
    if [[ "$total_pages" -gt 1 ]] || true; then
        args+=("" "" "")  # separator

        if [[ "$page" -gt 1 ]]; then
            args+=("Previous" "${KEY_PREV:-o}" "run-shell '$SCRIPTS_DIR/tracker.sh menu $(( page - 1 ))'")
        fi

        if [[ "$page" -lt "$total_pages" ]]; then
            args+=("Next" "${KEY_NEXT:-i}" "run-shell '$SCRIPTS_DIR/tracker.sh menu $(( page + 1 ))'")
        fi

        args+=("Quit" "${KEY_QUIT:-q}" "")
    fi

    tmux display-menu "${args[@]}"
}

# ── reap dead ─────────────────────────────────────────────────────────

_reap_dead() {
    [[ -f "$DB" ]] || return 0

    local stamp="$TRACKER_DIR/.last_reap"
    if [[ -f "$stamp" ]]; then
        local now age
        now=$(date +%s)
        age=$(( now - $(_file_mtime "$stamp" 2>/dev/null || echo 0) ))
        [[ "$age" -lt 30 ]] && return 0
    fi
    touch "$stamp"

    local pane_info
    pane_info=$(tmux list-panes -a -F '#{pane_id} #{pane_pid}' 2>/dev/null) || return 0

    local alive_panes="" claude_panes=""
    while read -r pane shell_pid; do
        [[ -z "$pane" ]] && continue
        alive_panes+="$pane"$'\n'
        pgrep -P "$shell_pid" -x "claude" >/dev/null 2>/dev/null && claude_panes+="$pane"$'\n'
    done <<< "$pane_info"

    local rows changed=0
    rows=$(sql "SELECT session_id, tmux_pane, status FROM sessions
                WHERE tmux_pane IS NOT NULL AND tmux_pane != '';") || return 0
    while IFS='|' read -r sid pane st; do
        [[ -z "$sid" ]] && continue
        # Dead pane → always delete
        if ! printf '%s' "$alive_panes" | grep -qx "$pane"; then
            sql "DELETE FROM sessions WHERE session_id='$sid';"
            changed=1
        # Live pane, no claude process, working/blocked → delete (Ctrl+C case)
        elif [[ "$st" != "idle" ]] \
          && ! printf '%s' "$claude_panes" | grep -qx "$pane"; then
            sql "DELETE FROM sessions WHERE session_id='$sid';"
            changed=1
        fi
    done <<< "$rows"

    # Reap paneless sessions stale for >10 minutes (e.g. leaked test data)
    local paneless_del
    paneless_del=$(sql "DELETE FROM sessions WHERE (tmux_pane IS NULL OR tmux_pane='')
         AND updated_at < unixepoch() - 600; SELECT changes();")
    [[ "${paneless_del:-0}" -gt 0 ]] && changed=1

    if [[ "$changed" -eq 1 ]]; then _render_cache; fi
}

# ── cleanup ───────────────────────────────────────────────────────────

cmd_cleanup() {
    [[ -f "$DB" ]] || return 0

    sql "DELETE FROM sessions WHERE updated_at < unixepoch() - 86400;"

    local alive
    alive=$(tmux list-panes -a -F '#{pane_id}' 2>/dev/null || true)

    if [[ -n "$alive" ]]; then
        local rows
        rows=$(sql "SELECT session_id, tmux_pane FROM sessions
                    WHERE tmux_pane IS NOT NULL AND tmux_pane != '';") || true
        while IFS='|' read -r sid pane; do
            [[ -z "$sid" ]] && continue
            if ! printf '%s\n' "$alive" | grep -qx "$pane"; then
                sql "DELETE FROM sessions WHERE session_id='$sid';"
            fi
        done <<< "$rows"
    fi

    _render_cache
    echo "Cleanup complete"
}

# ── scan ──────────────────────────────────────────────────────────────

cmd_scan() {
    [[ -f "$DB" ]] || return 0

    # Throttle: scan at most once every 30 seconds
    local stamp="$TRACKER_DIR/.last_scan"
    if [[ -f "$stamp" ]]; then
        local now age
        now=$(date +%s)
        age=$(( now - $(_file_mtime "$stamp" 2>/dev/null || echo 0) ))
        [[ "$age" -lt 30 ]] && return 0
    fi
    touch "$stamp"

    local changed=0

    # Find tmux panes whose shell has a claude child process
    local pane_ids
    pane_ids=$(tmux list-panes -a -F '#{pane_id} #{pane_pid}' 2>/dev/null) || return 0

    while read -r pane shell_pid; do
        [[ -z "$pane" ]] && continue

        # Check if this shell has a claude child process
        pgrep -P "$shell_pid" -x "claude" >/dev/null 2>/dev/null || continue

        # Get pane context
        local cwd project branch target
        cwd=$(tmux display-message -t "$pane" -p '#{pane_current_path}' 2>/dev/null) || continue
        [[ -z "$cwd" ]] && continue
        project=$(basename "$cwd")
        branch=$(git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
        target=$(tmux display-message -t "$pane" \
            -p '#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null || true)

        # Atomic conditional insert — avoids TOCTOU race with hook-based registration.
        # If any session already owns this pane, the INSERT is skipped entirely.
        local sid="scan-${pane}"
        sql "INSERT INTO sessions
             (session_id, status, cwd, project_name, git_branch, tmux_pane, tmux_target)
             SELECT '$(sql_esc "$sid")', 'idle',
                    '$(sql_esc "$cwd")', '$(sql_esc "$project")',
                    '$(sql_esc "$branch")', '$(sql_esc "$pane")',
                    '$(sql_esc "$target")'
             WHERE NOT EXISTS (SELECT 1 FROM sessions WHERE tmux_pane='$(sql_esc "$pane")');"
        changed=1
    done <<< "$pane_ids"

    [[ "$changed" -eq 1 ]] && _render_cache
}

# ── goto ──────────────────────────────────────────────────────────────

cmd_goto() {
    local target="$1"
    local sess="${target%%:*}"
    local win="${target%.*}"
    tmux switch-client -t "$sess" 2>/dev/null || true
    tmux select-window -t "$win" 2>/dev/null || true
    tmux select-pane -t "$target" 2>/dev/null || true
}

# ── main ──────────────────────────────────────────────────────────────

case "${1:-}" in
    init)       cmd_init ;;
    hook)       cmd_hook "${2:?Usage: tracker.sh hook <event>}" ;;
    status-bar) cmd_status_bar ;;
    refresh)    cmd_refresh ;;
    menu)       _reap_dead 2>/dev/null || true; cmd_scan 2>/dev/null || true; cmd_menu "${2:-1}" ;;
    goto)       cmd_goto "${2:?Usage: tracker.sh goto <target>}" ;;
    scan)       cmd_scan ;;
    cleanup)    cmd_cleanup ;;
    *)          echo "Usage: tracker.sh {init|hook|status-bar|refresh|menu|scan|cleanup|goto}" >&2
                exit 1 ;;
esac
