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
    COALESCE(SUM(CASE WHEN status='completed' THEN 1 ELSE 0 END),0) || '|' ||
    COALESCE((SELECT (unixepoch()-MIN(updated_at))/60 FROM sessions WHERE status='blocked'),0)
    FROM sessions"

_fire_transition_hook() {
    local from="$1" to="$2" sid="$3" project="$4"
    [[ "${_HAS_HOOKS:-0}" == "0" ]] && return 0
    local hook_var="HOOK_ON_${to^^}"
    local cmd="${!hook_var:-}"
    [[ -n "$cmd" ]] && ($cmd "$from" "$to" "$sid" "$project" &) 2>/dev/null
    [[ -n "${HOOK_ON_TRANSITION:-}" ]] && ($HOOK_ON_TRANSITION "$from" "$to" "$sid" "$project" &) 2>/dev/null
    return 0
}

# ── init ──────────────────────────────────────────────────────────────

cmd_init() {
    mkdir -p "$TRACKER_DIR"
    sqlite3 "$DB" <<'SQL'
PRAGMA journal_mode=WAL;
PRAGMA busy_timeout=100;

-- DROP + CREATE: sessions are ephemeral, re-init is safe.
-- Required when upgrading CHECK constraint (e.g. adding 'completed').
DROP TABLE IF EXISTS sessions;
CREATE TABLE sessions (
    session_id    TEXT PRIMARY KEY,
    status        TEXT NOT NULL DEFAULT 'working'
        CHECK(status IN ('working', 'blocked', 'idle', 'completed')),
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

    # _ensure_session only for session-creating hooks.
    # Hot-path hooks (PostToolUse, PostToolUseFailure, Notification, Stop, TeammateIdle) skip this
    # — their UPDATEs are no-ops if session doesn't exist yet.
    # SessionStart creates as idle; UserPromptSubmit creates as working.
    case "$event" in
        SessionStart)     _ensure_session "$sid" "$json" "idle" ;;
        UserPromptSubmit) _ensure_session "$sid" "$json" "working" ;;
    esac

    local __changed=1 __render="" __json="$json" __old_status="" __teammate_sid=""
    case "$event" in
        SessionStart)     ;; # _ensure_session already created as idle
        UserPromptSubmit) _hook_prompt "$sid" "$json" ;;
        PostToolUse)      _hook_post_tool "$sid" ;;
        PostToolUseFailure) _hook_post_tool "$sid" ;;
        Stop)             _hook_stop "$sid" ;;
        Notification)     _hook_notification "$sid" ;;
        SessionEnd)       sql "DELETE FROM sessions WHERE session_id='$sid';" ;;
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

    # Fire transition hooks
    if [[ -n "$__old_status" ]]; then
        local _hook_new_status _hook_sid _hook_project
        case "$event" in
            TeammateIdle)
                _hook_new_status="idle"
                _hook_sid="${__teammate_sid:-$sid}"
                ;;
            UserPromptSubmit)
                _hook_new_status="working"
                _hook_sid="$sid"
                ;;
            PostToolUse|PostToolUseFailure)
                _hook_new_status="working"
                _hook_sid="$sid"
                ;;
            Stop)
                _hook_new_status="completed"
                _hook_sid="$sid"
                ;;
            Notification)
                _hook_new_status="blocked"
                _hook_sid="$sid"
                ;;
            *) _hook_new_status="" ;;
        esac
        if [[ -n "$_hook_new_status" && "$__old_status" != "$_hook_new_status" ]]; then
            _hook_project=$(sql "SELECT project_name FROM sessions WHERE session_id='$(sql_esc "$_hook_sid")';")
            _fire_transition_hook "$__old_status" "$_hook_new_status" "$_hook_sid" "$_hook_project"
        fi
    fi
}

_ensure_session() {
    local sid="$1" json="${2:-}" init_status="${3:-working}"

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

    # One Claude per pane — evict stale sessions on the same pane.
    # Atomic: DELETE + INSERT in one sqlite3 process to prevent render seeing N-1 sessions.
    if [[ -n "$pane" ]]; then
        sql "DELETE FROM sessions WHERE tmux_pane='$(sql_esc "$pane")' AND session_id!='$sid';
             INSERT OR IGNORE INTO sessions
             (session_id, status, cwd, project_name, git_branch, tmux_pane, tmux_target)
             VALUES ('$sid', '$init_status',
                     '$(sql_esc "$cwd")', '$(sql_esc "$project")',
                     '$(sql_esc "$branch")', '$(sql_esc "$pane")',
                     '$(sql_esc "$target")');"
    else
        sql "INSERT OR IGNORE INTO sessions
             (session_id, status, cwd, project_name, git_branch, tmux_pane, tmux_target)
             VALUES ('$sid', '$init_status',
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

_hook_prompt() {
    local sid="$1"
    __old_status=$(sql "SELECT status FROM sessions WHERE session_id='$sid';")
    sql "UPDATE sessions SET status='working', updated_at=unixepoch()
         WHERE session_id='$sid';"
}

# Hot path: SELECT old status + UPDATE + render in one sqlite3 call
_hook_post_tool() {
    local sid="$1"
    local _result
    _result=$(sql "SELECT status FROM sessions WHERE session_id='$sid';
         UPDATE sessions SET status='working', updated_at=unixepoch()
         WHERE session_id='$sid' AND status!='working';
         SELECT CASE WHEN changes() = 0 THEN '' ELSE ($_RENDER_SQL) END;")
    # Two output lines when changed: old_status\nrender_data
    # One line when no-op: old_status (empty CASE produces no output)
    if [[ "$_result" == *$'\n'* ]]; then
        __old_status="${_result%%$'\n'*}"
        __render="${_result#*$'\n'}"
    else
        __old_status="$_result"
        __render=""
    fi
    if [[ -z "$__render" ]]; then __changed=0; fi
}

_hook_stop() {
    local sid="$1"
    __old_status=$(sql "SELECT status FROM sessions WHERE session_id='$sid';")
    sql "UPDATE sessions SET status='completed', updated_at=unixepoch()
         WHERE session_id='$sid' AND status IN ('working', 'blocked');"
}

# Hot path: SELECT old status + UPDATE + render in one sqlite3 call
# Only permission_prompt and elicitation_dialog should set blocked.
# Other notification types (idle_prompt, auth_success) are not permission waits.
# The hook config matcher should filter to these, but we guard here too.
_hook_notification() {
    local sid="$1"
    local ntype
    ntype=$(_json_val "$__json" "notification_type")
    if [[ -n "$ntype" && "$ntype" != "permission_prompt" && "$ntype" != "elicitation_dialog" ]]; then
        __changed=0; return 0
    fi
    local _result
    _result=$(sql "SELECT status FROM sessions WHERE session_id='$sid';
         UPDATE sessions SET status='blocked', updated_at=unixepoch()
         WHERE session_id='$sid' AND status = 'working';
         SELECT CASE WHEN changes() = 0 THEN '' ELSE ($_RENDER_SQL) END;")
    if [[ "$_result" == *$'\n'* ]]; then
        __old_status="${_result%%$'\n'*}"
        __render="${_result#*$'\n'}"
    else
        __old_status="$_result"
        __render=""
    fi
    if [[ -z "$__render" ]]; then __changed=0; fi
}

_hook_teammate_idle() {
    local json="$1"
    local tid
    tid=$(_json_val "$json" "teammate_id")
    [[ -z "$tid" ]] && tid=$(_json_val "$json" "session_id")
    [[ -z "$tid" ]] && return 0
    local raw_tid="$tid"
    tid=$(sql_esc "$tid")
    __old_status=$(sql "SELECT status FROM sessions WHERE session_id='$tid';")
    sql "UPDATE sessions SET status='idle', updated_at=unixepoch()
         WHERE session_id='$tid';"
    __teammate_sid="$raw_tid"
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

# Write formatted cache from pre-fetched "w|b|i|c|dur" data
_write_cache() {
    local w b i c dur
    IFS='|' read -r w b i c dur <<< "$1"
    w="${w:-0}"; b="${b:-0}"; i="${i:-0}"; c="${c:-0}"; dur="${dur:-0}"
    local result=""
    result+="#[fg=${COLOR_IDLE}]${i}${ICON_IDLE:-.}#[default] "
    result+="#[fg=${COLOR_WORKING}]${w}${ICON_WORKING:-*}#[default] "
    result+="#[fg=${COLOR_COMPLETED}]${c}${ICON_COMPLETED:-+}#[default] "

    if [[ "$b" -gt 0 ]]; then
        local suffix=""
        if [[ "$dur" -ge 60 ]]; then
            suffix="$((dur / 60))h"
        elif [[ "$dur" -gt 0 ]]; then
            suffix="${dur}m"
        fi
        result+="#[fg=${COLOR_BLOCKED}]${b}${ICON_BLOCKED:-!}${suffix}#[default]"
    else
        result+="#[fg=${COLOR_BLOCKED}]${b}${ICON_BLOCKED:-!}#[default]"
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
        COALESCE(SUM(CASE WHEN status='completed' THEN 1 ELSE 0 END),0),
        COALESCE((SELECT (unixepoch()-MIN(updated_at))/60 FROM sessions
                  WHERE status='blocked'),0)
        FROM sessions;") || return 0
    [[ -z "$counts" ]] && counts="0|0|0|0|0"

    local project=""
    if [[ "${SHOW_PROJECT:-0}" == "1" ]]; then
        project=$(sql "SELECT project_name FROM sessions
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
    # Auto-clear completed on focused pane, but only after a grace period
    # so the completed indicator is visible for at least one full refresh cycle.
    # tmux resolves #{pane_id} at run-shell call time, not subprocess context.
    local grace
    grace=$(tmux show-option -gqv status-interval 2>/dev/null) || grace=15
    grace="${grace:-15}"
    local has_stale_completed
    has_stale_completed=$(sql "SELECT 1 FROM sessions WHERE status='completed'
         AND updated_at <= unixepoch() - $grace LIMIT 1;")
    if [[ -n "$has_stale_completed" ]]; then
        tmux run-shell -b "$SCRIPTS_DIR/tracker.sh pane-focus #{pane_id}" 2>/dev/null || true
    fi
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
            WHEN 'blocked' THEN 0 WHEN 'completed' THEN 1 WHEN 'working' THEN 2 ELSE 3
        END, updated_at DESC
        LIMIT $items_per_page OFFSET $offset;") || true

    local title="Claude Agents"
    [[ "$total_pages" -gt 1 ]] && title="Claude Agents ($page/$total_pages)"

    local args=(-T "$title")
    while IFS='|' read -r _sid status project branch target; do
        [[ -z "$_sid" ]] && continue
        local icon label
        case "$status" in
            blocked)   icon="${ICON_BLOCKED:-!}" ;;
            completed) icon="${ICON_COMPLETED:-+}" ;;
            working)   icon="${ICON_WORKING:-*}" ;;
            *)         icon="${ICON_IDLE:-.}" ;;
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
        elif [[ "$st" != "idle" && "$st" != "completed" ]] \
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
    local _goto_sid _goto_project
    _goto_sid=$(sql "SELECT session_id FROM sessions
         WHERE tmux_target='$(sql_esc "$target")' AND status='completed' LIMIT 1;") || true
    if [[ -n "$_goto_sid" ]]; then
        sql "UPDATE sessions SET status='idle', updated_at=unixepoch()
             WHERE session_id='$(sql_esc "$_goto_sid")' AND status='completed';" 2>/dev/null || true
        _load_config_fast
        _goto_project=$(sql "SELECT project_name FROM sessions WHERE session_id='$(sql_esc "$_goto_sid")';") || true
        _fire_transition_hook "completed" "idle" "$_goto_sid" "$_goto_project"
    fi
    _render_cache 2>/dev/null || true
    tmux refresh-client -S 2>/dev/null || true
}

# ── pane-focus ────────────────────────────────────────────────────────

cmd_pane_focus() {
    [[ -f "$DB" ]] || return 0
    local pane_id="$1"
    local _focus_sids
    _focus_sids=$(sql "SELECT session_id FROM sessions
         WHERE tmux_pane='$(sql_esc "$pane_id")' AND status='completed';") || true
    [[ -z "$_focus_sids" ]] && return 0
    sql "UPDATE sessions SET status='idle', updated_at=unixepoch()
         WHERE tmux_pane='$(sql_esc "$pane_id")' AND status='completed';"
    _load_config_fast
    while IFS= read -r _fsid; do
        [[ -z "$_fsid" ]] && continue
        local _fproject
        _fproject=$(sql "SELECT project_name FROM sessions WHERE session_id='$(sql_esc "$_fsid")';") || true
        _fire_transition_hook "completed" "idle" "$_fsid" "$_fproject"
    done <<< "$_focus_sids"
    _render_cache 2>/dev/null || true
    tmux refresh-client -S 2>/dev/null || true
}

# ── main ──────────────────────────────────────────────────────────────

case "${1:-}" in
    init)       cmd_init ;;
    hook)       cmd_hook "${2:?Usage: tracker.sh hook <event>}" ;;
    status-bar) cmd_status_bar ;;
    refresh)    cmd_refresh ;;
    menu)       tmux display-message "Opening..." 2>/dev/null || true; _reap_dead 2>/dev/null || true; cmd_scan 2>/dev/null || true; cmd_menu "${2:-1}" ;;
    goto)       cmd_goto "${2:?Usage: tracker.sh goto <target>}" ;;
    pane-focus) cmd_pane_focus "${2:?Usage: tracker.sh pane-focus <pane_id>}" ;;
    scan)       cmd_scan ;;
    cleanup)    cmd_cleanup ;;
    *)          echo "Usage: tracker.sh {init|hook|status-bar|refresh|menu|scan|cleanup|goto|pane-focus}" >&2
                exit 1 ;;
esac
