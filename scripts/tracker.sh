#!/usr/bin/env bash
set -euo pipefail

# ── source helpers ───────────────────────────────────────────────────

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPTS_DIR/helpers.sh"

# Load config (tmux options with defaults)
load_config 2>/dev/null || true

TRACKER_DIR="$HOME/.tmux-claude-agent-tracker"
DB="$TRACKER_DIR/tracker.db"
CACHE="$TRACKER_DIR/status_cache"

sql() { printf '.timeout 100\n%s\n' "$*" | sqlite3 "$DB"; }
sql_sep() { local s="$1"; shift; printf '.timeout 100\n%s\n' "$*" | sqlite3 -separator "$s" "$DB"; }
sql_esc() { printf '%s' "${1//\'/\'\'}"; }

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
    json=$(cat) || json='{}'

    local sid
    sid=$(printf '%s' "$json" | jq -r '.session_id // empty' 2>/dev/null) || true
    [[ -z "$sid" ]] && return 0

    # Universal safety net: any non-delete hook registers the session
    case "$event" in
        SessionEnd|SubagentStop) ;;
        *) _ensure_session "$sid" "$json" ;;
    esac

    case "$event" in
        SessionStart)     _hook_session_start "$sid" "$json" ;;
        UserPromptSubmit) _hook_prompt "$sid" "$json" ;;
        PostToolUse)      _hook_post_tool "$sid" "$json" ;;
        Stop)             _hook_stop "$sid" "$json" ;;
        Notification)     _hook_notification "$sid" "$json" ;;
        SessionEnd)       sql "DELETE FROM sessions WHERE session_id='$sid';" ;;
        SubagentStart)    _hook_subagent_start "$sid" "$json" ;;
        SubagentStop)     _hook_subagent_stop "$json" ;;
        TeammateIdle)     _hook_teammate_idle "$json" ;;
        *) return 0 ;;
    esac

    _render_cache
    tmux refresh-client -S 2>/dev/null || true
}

_ensure_session() {
    local sid="$1" json="${2:-}"

    local cwd project branch pane target
    cwd=$(printf '%s' "$json" | jq -r '.cwd // empty' 2>/dev/null) || true
    [[ -z "$cwd" ]] && cwd="${PWD}"
    project=$(basename "$cwd")
    branch=$(git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
    pane="${TMUX_PANE:-}"
    target=""
    if [[ -n "$pane" ]]; then
        target=$(tmux display-message -t "$pane" \
            -p '#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null || true)
    fi

    # Create if missing
    sql "INSERT OR IGNORE INTO sessions
         (session_id, status, cwd, project_name, git_branch, tmux_pane, tmux_target)
         VALUES ('$sid', 'working',
                 '$(sql_esc "$cwd")', '$(sql_esc "$project")',
                 '$(sql_esc "$branch")', '$(sql_esc "$pane")',
                 '$(sql_esc "$target")');"

    # Backfill tmux info if missing (session existed but lacked pane data)
    if [[ -n "$pane" ]]; then
        sql "UPDATE sessions SET tmux_pane='$(sql_esc "$pane")',
             tmux_target='$(sql_esc "$target")'
             WHERE session_id='$sid' AND (tmux_pane IS NULL OR tmux_pane='');"
    fi
}

_hook_session_start() {
    local sid="$1" json="$2"
    local cwd project branch pane target

    cwd=$(printf '%s' "$json" | jq -r '.cwd // empty' 2>/dev/null) || true
    [[ -z "$cwd" ]] && cwd="${PWD}"
    project=$(basename "$cwd")
    branch=$(git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null || true)

    pane="${TMUX_PANE:-}"
    target=""
    if [[ -n "$pane" ]]; then
        target=$(tmux display-message -t "$pane" \
            -p '#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null || true)
    fi

    sql "INSERT OR REPLACE INTO sessions
         (session_id, status, cwd, project_name, git_branch, tmux_pane, tmux_target)
         VALUES ('$sid', 'idle',
                 '$(sql_esc "$cwd")', '$(sql_esc "$project")',
                 '$(sql_esc "$branch")', '$(sql_esc "$pane")',
                 '$(sql_esc "$target")');"
}

_hook_prompt() {
    local sid="$1"
    sql "UPDATE sessions SET status='working', updated_at=unixepoch()
         WHERE session_id='$sid';"
}

_hook_post_tool() {
    local sid="$1" json="$2"
    sql "UPDATE sessions SET status='working', updated_at=unixepoch()
         WHERE session_id='$sid' AND status!='working';"
}

_hook_stop() {
    local sid="$1" json="$2"
    sql "UPDATE sessions SET status='idle', updated_at=unixepoch()
         WHERE session_id='$sid';"
}

_hook_notification() {
    local sid="$1" json="${2:-}"
    sql "UPDATE sessions SET status='blocked', updated_at=unixepoch()
         WHERE session_id='$sid' AND status='working';"
    if [[ "${SOUND:-0}" == "1" ]]; then
        afplay /System/Library/Sounds/Glass.aiff &
    fi
}

_hook_subagent_start() {
    local sid="$1" json="$2"
    local sub_id cwd project branch atype pane target

    sub_id=$(printf '%s' "$json" | jq -r '.subagent_id // empty' 2>/dev/null) || true
    [[ -z "$sub_id" ]] && sub_id="$sid"

    cwd=$(printf '%s' "$json" | jq -r '.cwd // empty' 2>/dev/null) || true
    [[ -z "$cwd" ]] && cwd="${PWD}"
    project=$(basename "$cwd")
    branch=$(git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
    atype=$(printf '%s' "$json" | jq -r '.subagent_type // "subagent"' 2>/dev/null) || true

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
    sub_id=$(printf '%s' "$json" | jq -r '.subagent_id // .session_id // empty' 2>/dev/null) || true
    [[ -n "$sub_id" ]] && sql "DELETE FROM sessions WHERE session_id='$sub_id';"
}

_hook_teammate_idle() {
    local json="$1"
    local tid
    tid=$(printf '%s' "$json" | jq -r '.teammate_id // .session_id // empty' 2>/dev/null) || true
    [[ -n "$tid" ]] && sql "UPDATE sessions SET status='idle', updated_at=unixepoch()
                            WHERE session_id='$tid';"
}

# ── render cache ──────────────────────────────────────────────────────

_render_cache() {
    local w b i dur result=""
    w=$(sql "SELECT COUNT(*) FROM sessions WHERE status='working';")
    b=$(sql "SELECT COUNT(*) FROM sessions WHERE status='blocked';")
    i=$(sql "SELECT COUNT(*) FROM sessions WHERE status='idle';")

    result+="#[fg=${COLOR_IDLE}]${i}.#[default] "
    result+="#[fg=${COLOR_WORKING}]${w}*#[default] "

    if [[ "$b" -gt 0 ]]; then
        dur=$(sql "SELECT (unixepoch() - MIN(updated_at)) / 60
                   FROM sessions WHERE status='blocked';")
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

    printf '%s' "${result% }" > "$CACHE.tmp"
    mv -f "$CACHE.tmp" "$CACHE"
}

# ── status-bar ────────────────────────────────────────────────────────

cmd_status_bar() {
    [[ -f "$CACHE" ]] && cat "$CACHE"
    true
}

# ── menu ──────────────────────────────────────────────────────────────

cmd_menu() {
    [[ -f "$DB" ]] || return 0

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

    local alive_panes
    alive_panes=$(tmux list-panes -a -F '#{pane_id}' 2>/dev/null) || return 0

    local changed=0
    local rows
    rows=$(sql "SELECT session_id, tmux_pane FROM sessions WHERE tmux_pane IS NOT NULL AND tmux_pane != '';") || return 0

    while IFS='|' read -r sid pane; do
        [[ -z "$sid" ]] && continue

        # Pane dead? Remove.
        if ! printf '%s\n' "$alive_panes" | grep -qx "$pane"; then
            sql "DELETE FROM sessions WHERE session_id='$sid';"
            changed=1
            continue
        fi

        # Pane alive but no claude process? Remove.
        local shell_pid
        shell_pid=$(tmux display-message -t "$pane" -p '#{pane_pid}' 2>/dev/null) || continue
        if [[ -n "$shell_pid" ]] && ! pgrep -P "$shell_pid" -xq "claude" 2>/dev/null; then
            sql "DELETE FROM sessions WHERE session_id='$sid';"
            changed=1
        fi
    done <<< "$rows"

    [[ "$changed" -eq 1 ]] && _render_cache
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
        age=$(( now - $(stat -f %m "$stamp" 2>/dev/null || echo 0) ))
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
        pgrep -P "$shell_pid" -xq "claude" 2>/dev/null || continue

        # Already tracked by this pane?
        local tracked
        tracked=$(sql "SELECT 1 FROM sessions WHERE tmux_pane='$(sql_esc "$pane")';")
        [[ -n "$tracked" ]] && continue

        # Get pane context
        local cwd project branch target
        cwd=$(tmux display-message -t "$pane" -p '#{pane_current_path}' 2>/dev/null) || continue
        [[ -z "$cwd" ]] && continue
        project=$(basename "$cwd")
        branch=$(git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
        target=$(tmux display-message -t "$pane" \
            -p '#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null || true)

        # Use pane ID as synthetic session_id (real ID unknown)
        local sid="scan-${pane}"
        sql "INSERT OR IGNORE INTO sessions
             (session_id, status, cwd, project_name, git_branch, tmux_pane, tmux_target)
             VALUES ('$(sql_esc "$sid")', 'idle',
                     '$(sql_esc "$cwd")', '$(sql_esc "$project")',
                     '$(sql_esc "$branch")', '$(sql_esc "$pane")',
                     '$(sql_esc "$target")');"
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
    status-bar) _reap_dead 2>/dev/null || true; cmd_scan 2>/dev/null || true; cmd_status_bar ;;
    menu)       _reap_dead 2>/dev/null || true; cmd_scan 2>/dev/null || true; cmd_menu "${2:-1}" ;;
    goto)       cmd_goto "${2:?Usage: tracker.sh goto <target>}" ;;
    scan)       cmd_scan ;;
    cleanup)    cmd_cleanup ;;
    *)          echo "Usage: tracker.sh {init|hook|status-bar|menu|scan|cleanup|goto}" >&2
                exit 1 ;;
esac
