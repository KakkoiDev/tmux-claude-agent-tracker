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
json_esc() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/ }"
    printf '%s' "$s"
}

# ── debug logging ────────────────────────────────────────────────────

_debug_log() {
    [[ "${DEBUG_LOG:-0}" == "1" ]] || return 0
    local _log="$TRACKER_DIR/debug.log"
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$_log"
    local _lc
    _lc=$(wc -l < "$_log" 2>/dev/null) || return 0
    if [[ "${_lc:-0}" -gt 1500 ]]; then
        tail -n 1000 "$_log" > "$_log.tmp" && mv -f "$_log.tmp" "$_log"
    fi
}

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
    COALESCE(SUM(CASE WHEN status='completed' AND task_count > 0 THEN task_count WHEN status='completed' THEN 1 ELSE 0 END),0) || '|' ||
    COALESCE((SELECT (unixepoch()-MIN(updated_at))/60 FROM sessions WHERE status='blocked' AND COALESCE(agent_type,'')=''),0)
    FROM sessions WHERE COALESCE(agent_type,'')=''"

_fire_transition_hook() {
    local from="$1" to="$2" sid="$3" project="$4"
    [[ "${_HAS_HOOKS:-0}" == "0" ]] && return 0
    local hook_var="HOOK_ON_$(printf '%s' "$to" | tr '[:lower:]' '[:upper:]')"
    local cmd="${!hook_var:-}"
    [[ -n "$cmd" ]] && ($cmd "$from" "$to" "$sid" "$project" &) 2>/dev/null
    [[ -n "${HOOK_ON_TRANSITION:-}" ]] && ($HOOK_ON_TRANSITION "$from" "$to" "$sid" "$project" &) 2>/dev/null
    return 0
}

_ensure_schema() {
    [[ -f "$DB" ]] || return 0
    if [[ ! -f "$TRACKER_DIR/.schema_v2" ]]; then
        sql "ALTER TABLE sessions ADD COLUMN subagent_count INTEGER NOT NULL DEFAULT 0;" 2>/dev/null || true
        touch "$TRACKER_DIR/.schema_v2"
    fi
    if [[ ! -f "$TRACKER_DIR/.schema_v3" ]]; then
        sql "ALTER TABLE sessions ADD COLUMN agent_client TEXT NOT NULL DEFAULT 'claude';" 2>/dev/null || true
        touch "$TRACKER_DIR/.schema_v3"
    fi
}

_session_client() {
    local sid="$1"
    local client
    client=$(sql "SELECT COALESCE(agent_client,'claude') FROM sessions WHERE session_id='$(sql_esc "$sid")';" 2>/dev/null || true)
    printf '%s' "${client:-claude}"
}

_map_codex_event() {
    local ntype="$1"
    case "$ntype" in
        *permission*|*approval*|*consent*) echo "PermissionRequest" ;;
        *complete*|*completed*|*finish*|*finished*|*done*) echo "Stop" ;;
        *start*|*started*|*resume*|*resumed*) echo "PostToolUse" ;;
        *fail*|*failed*|*error*|*reject*|*denied*) echo "PostToolUseFailure" ;;
        *) echo "PostToolUse" ;;
    esac
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
    task_count    INTEGER NOT NULL DEFAULT 0,
    subagent_count INTEGER NOT NULL DEFAULT 0,
    agent_client  TEXT NOT NULL DEFAULT 'claude',
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
    _ensure_schema
    _load_config_fast
    local event="$1"
    local json
    read -r json || true
    [[ -z "$json" ]] && json='{}'

    local sid raw_sid
    raw_sid=$(_json_val "$json" "session_id")
    [[ -z "$raw_sid" ]] && return 0
    sid=$(sql_esc "$raw_sid")

    _debug_log "HOOK $event sid=$raw_sid client=$(_session_client "$raw_sid")"

    # _ensure_session only for session-creating hooks.
    # Hot-path hooks (PostToolUse, PostToolUseFailure, Notification, PermissionRequest, Stop, TeammateIdle) skip this
    # - their UPDATEs are no-ops if session doesn't exist yet.
    # SessionStart creates as idle; UserPromptSubmit creates as working.
    case "$event" in
        SessionStart)     _ensure_session "$sid" "$json" "idle" "claude" ;;
        UserPromptSubmit) _ensure_session "$sid" "$json" "working" "claude" ;;
    esac

    local __changed=1 __render="" __json="$json" __old_status="" __teammate_sid=""
    case "$event" in
        SessionStart)     ;; # _ensure_session already created as idle
        UserPromptSubmit) _hook_prompt "$sid" "$json" ;;
        PostToolUse)      _hook_post_tool "$sid" ;;
        PostToolUseFailure) _hook_post_tool "$sid" ;;
        Stop)             _hook_stop "$sid" ;;
        Notification)     _hook_notification "$sid" ;;
        PermissionRequest) _hook_permission_request "$sid" ;;
        TaskCompleted)    _hook_task_completed "$sid" ;;
        SessionEnd)       sql "DELETE FROM sessions WHERE session_id='$sid';" ;;
        TeammateIdle)     _hook_teammate_idle "$json" ;;
        SubagentStart)
            local _agent_id _agent_type
            _agent_id=$(_json_val "$json" "agent_id")
            _agent_type=$(_json_val "$json" "agent_type")
            sql "UPDATE sessions SET subagent_count = subagent_count + 1
                 WHERE session_id='$sid';"
            _debug_log "subagent_start parent=$sid agent_id=$_agent_id agent_type=$_agent_type"
            __changed=0 ;;
        SubagentStop)
            local _agent_id _agent_type
            _agent_id=$(_json_val "$json" "agent_id")
            _agent_type=$(_json_val "$json" "agent_type")
            _hook_subagent_stop "$sid"
            _debug_log "subagent_stop parent=$sid agent_id=$_agent_id agent_type=$_agent_type" ;;
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
            Notification|PermissionRequest)
                _hook_new_status="blocked"
                _hook_sid="$sid"
                ;;
            TaskCompleted) _hook_new_status="" ;;
            *) _hook_new_status="" ;;
        esac
        if [[ -n "$_hook_new_status" && "$__old_status" != "$_hook_new_status" ]]; then
            _hook_project=$(sql "SELECT project_name FROM sessions WHERE session_id='$(sql_esc "$_hook_sid")';")
            _fire_transition_hook "$__old_status" "$_hook_new_status" "$_hook_sid" "$_hook_project"
        fi
    fi
}

_ensure_session() {
    local sid="$1" json="${2:-}" init_status="${3:-working}" client="${4:-claude}"

    # Fast path: session already registered with pane info — skip git/tmux overhead
    local existing
    existing=$(sql "SELECT 1 FROM sessions WHERE session_id='$sid' AND tmux_pane != '' LIMIT 1;")
    [[ -n "$existing" ]] && return 0

    local cwd project branch pane target atype
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

    # Detect worktree sessions via cwd pattern
    atype=""
    if [[ "$cwd" == *"/.claude/worktrees/"* ]]; then
        atype="worktree"
    fi

    # One Claude per pane — evict stale sessions on the same pane.
    # Atomic: DELETE + INSERT in one sqlite3 process to prevent render seeing N-1 sessions.
    if [[ -n "$pane" ]]; then
        sql "DELETE FROM sessions WHERE tmux_pane='$(sql_esc "$pane")' AND session_id!='$sid';
             INSERT OR IGNORE INTO sessions
             (session_id, status, cwd, project_name, git_branch, agent_type, agent_client, tmux_pane, tmux_target)
             VALUES ('$sid', '$init_status',
                     '$(sql_esc "$cwd")', '$(sql_esc "$project")',
                     '$(sql_esc "$branch")', '$(sql_esc "$atype")', '$(sql_esc "$client")',
                     '$(sql_esc "$pane")', '$(sql_esc "$target")');"
    else
        sql "INSERT OR IGNORE INTO sessions
             (session_id, status, cwd, project_name, git_branch, agent_type, agent_client, tmux_pane, tmux_target)
             VALUES ('$sid', '$init_status',
                     '$(sql_esc "$cwd")', '$(sql_esc "$project")',
                     '$(sql_esc "$branch")', '$(sql_esc "$atype")', '$(sql_esc "$client")', '', '');"
    fi

    # Backfill tmux info if missing (session existed but lacked pane data)
    if [[ -n "$pane" ]]; then
        sql "UPDATE sessions SET tmux_pane='$(sql_esc "$pane")',
             tmux_target='$(sql_esc "$target")',
             agent_client='$(sql_esc "$client")'
             WHERE session_id='$sid' AND (tmux_pane IS NULL OR tmux_pane='');"
    fi
    _debug_log "session_ensure sid=$sid path=[$client] $cwd pane=${pane:-none}"
}

cmd_codex_notify() {
    [[ -f "$DB" ]] || return 0
    _ensure_schema

    local payload="${2:-}"
    if [[ -z "$payload" ]]; then
        read -r payload || true
    fi
    [[ -z "$payload" ]] && payload='{}'

    local sid ntype cwd event sid_esc synth
    sid=$(_json_val "$payload" "session_id")
    [[ -z "$sid" ]] && sid=$(_json_val "$payload" "conversation_id")
    [[ -z "$sid" ]] && sid=$(_json_val "$payload" "thread_id")
    [[ -z "$sid" ]] && sid=$(_json_val "$payload" "turn_id")
    if [[ -z "$sid" && -n "${TMUX_PANE:-}" ]]; then
        sid="codex-pane-${TMUX_PANE#%}"
    fi
    [[ -z "$sid" ]] && return 0
    sid_esc=$(sql_esc "$sid")

    ntype=$(_json_val "$payload" "type")
    [[ -z "$ntype" ]] && ntype=$(_json_val "$payload" "event")
    cwd=$(_json_val "$payload" "cwd")
    [[ -z "$cwd" ]] && cwd="$PWD"

    # Ensure session exists before we map notify type to a synthetic hook event.
    synth="{\"session_id\":\"$(json_esc "$sid")\",\"cwd\":\"$(json_esc "$cwd")\"}"
    _ensure_session "$sid_esc" "$synth" "working" "codex"

    event=$(_map_codex_event "$ntype")
    if [[ "$event" == "PermissionRequest" ]]; then
        synth="{\"session_id\":\"$(json_esc "$sid")\",\"cwd\":\"$(json_esc "$cwd")\",\"notification_type\":\"permission_prompt\"}"
    fi

    printf '%s' "$synth" | cmd_hook "$event"
    sql "UPDATE sessions SET agent_client='codex', updated_at=unixepoch() WHERE session_id='$sid_esc';"
    _debug_log "codex_notify type=${ntype:-unknown} sid=$sid event=$event path=[codex] $cwd"
}

_hook_prompt() {
    local sid="$1"
    __old_status=$(sql "SELECT status FROM sessions WHERE session_id='$sid';")
    _debug_log "prompt sid=$sid old=$__old_status"
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
    _debug_log "post_tool sid=$sid old=$__old_status changed=$([ -n "$__render" ] && echo y || echo n)"
    if [[ -z "$__render" ]]; then __changed=0; fi
}

_hook_stop() {
    local sid="$1"
    local _info
    _info=$(sql_sep '|' "SELECT status, subagent_count FROM sessions WHERE session_id='$sid';")
    __old_status="${_info%%|*}"
    local _subs="${_info#*|}"
    _subs="${_subs:-0}"
    _debug_log "stop sid=$sid old=$__old_status subagents=$_subs"
    # Don't mark completed while subagents are still running
    if [[ "$_subs" -gt 0 ]]; then
        return 0
    fi
    sql "UPDATE sessions SET status='completed', updated_at=unixepoch()
         WHERE session_id='$sid' AND status IN ('working', 'blocked');"
    # Deferred clear: clear completed only if user is focused on this pane.
    # Avoids the 15-60s wait for cmd_refresh when already watching the agent.
    _load_config_fast
    local delay="${COMPLETED_DELAY:-3}"
    if [[ -n "${TMUX_PANE:-}" && "$delay" -gt 0 ]] 2>/dev/null; then
        tmux run-shell -b "sleep $delay && $SCRIPTS_DIR/tracker.sh pane-focus-if-active $TMUX_PANE" 2>/dev/null || true
    fi
}

_hook_subagent_stop() {
    local sid="$1"
    local _result
    _result=$(sql_sep '|' "UPDATE sessions SET subagent_count = MAX(0, subagent_count - 1)
         WHERE session_id='$sid';
         SELECT status, subagent_count FROM sessions WHERE session_id='$sid';")
    __old_status="${_result%%|*}"
    local _subs="${_result#*|}"
    _subs="${_subs:-0}"
    # When last subagent finishes and parent is blocked, clear to working
    if [[ "$__old_status" == "blocked" ]]; then
        sql "UPDATE sessions SET status='working', updated_at=unixepoch()
             WHERE session_id='$sid' AND status='blocked';"
    fi
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
    _debug_log "notification sid=$sid type=$ntype old=$__old_status changed=$([ -n "$__render" ] && echo y || echo n)"
    if [[ -z "$__render" ]]; then __changed=0; fi
}

# PermissionRequest fires immediately when a permission dialog appears.
# More reliable than Notification (which has 4-41s upstream delay).
_hook_permission_request() {
    local sid="$1"
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
    _debug_log "permission_request sid=$sid old=$__old_status changed=$([ -n "$__render" ] && echo y || echo n)"
    if [[ -z "$__render" ]]; then __changed=0; fi
}

_hook_task_completed() {
    local sid="$1"
    sql "UPDATE sessions SET task_count = task_count + 1, updated_at=unixepoch()
         WHERE session_id='$sid';"
    _debug_log "task_completed sid=$sid"
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
    _debug_log "teammate_idle tid=$raw_tid old=$__old_status"
    sql "UPDATE sessions SET status='idle', agent_type='teammate', updated_at=unixepoch()
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
        COALESCE(SUM(CASE WHEN status='completed' AND task_count > 0 THEN task_count WHEN status='completed' THEN 1 ELSE 0 END),0),
        COALESCE((SELECT (unixepoch()-MIN(updated_at))/60 FROM sessions
                  WHERE status='blocked' AND COALESCE(agent_type,'')=''),0)
        FROM sessions WHERE COALESCE(agent_type,'')='';") || return 0
    [[ -z "$counts" ]] && counts="0|0|0|0|0"
    _debug_log "render counts=$counts"

    local project=""
    if [[ "${SHOW_PROJECT:-0}" == "1" ]]; then
        project=$(sql "SELECT project_name FROM sessions
                       WHERE COALESCE(agent_type,'')=''
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
         AND COALESCE(agent_type,'')=''
         AND updated_at <= unixepoch() - $grace LIMIT 1;")
    if [[ -n "$has_stale_completed" ]]; then
        tmux run-shell -b "$SCRIPTS_DIR/tracker.sh pane-focus #{pane_id}" 2>/dev/null || true
    fi
    # No stdout — #() renders empty string; display comes from #{@claude-tracker-status}
}

# ── menu ──────────────────────────────────────────────────────────────

cmd_menu() {
    [[ -f "$DB" ]] || return 0
    _ensure_schema
    [[ -z "${ITEMS_PER_PAGE:-}" ]] && { load_config 2>/dev/null || true; }

    local page="${1:-1}"
    local items_per_page="${ITEMS_PER_PAGE:-10}"

    # Total count
    local total
    total=$(sql "SELECT COUNT(*) FROM sessions WHERE COALESCE(agent_type,'')='';") || total=0
    [[ "$total" -eq 0 ]] && { tmux display-message "No active Claude agents"; return; }

    # Pagination math
    local total_pages=$(( (total + items_per_page - 1) / items_per_page ))
    [[ "$page" -lt 1 ]] && page=1
    [[ "$page" -gt "$total_pages" ]] && page="$total_pages"
    local offset=$(( (page - 1) * items_per_page ))

    local rows
    rows=$(sql_sep '|' "SELECT session_id, status, project_name,
               COALESCE(git_branch,''), COALESCE(tmux_target,''), COALESCE(agent_client,'claude')
        FROM sessions
        WHERE COALESCE(agent_type,'')=''
        ORDER BY CASE status
            WHEN 'blocked' THEN 0 WHEN 'completed' THEN 1 WHEN 'working' THEN 2 ELSE 3
        END, updated_at DESC
        LIMIT $items_per_page OFFSET $offset;") || true

    local title="Claude Agents"
    [[ "$total_pages" -gt 1 ]] && title="Claude Agents ($page/$total_pages)"

    local args=(-T "$title")
    while IFS='|' read -r _sid status project branch target client; do
        [[ -z "$_sid" ]] && continue
        local icon label
        case "$status" in
            blocked)   icon="${ICON_BLOCKED:-!}" ;;
            completed) icon="${ICON_COMPLETED:-+}" ;;
            working)   icon="${ICON_WORKING:-*}" ;;
            *)         icon="${ICON_IDLE:-.}" ;;
        esac

        label="${icon} [${client}] ${project}"
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
        _has_claude_child "$shell_pid" && claude_panes+="$pane"$'\n'
    done <<< "$pane_info"

    local rows changed=0
    rows=$(sql "SELECT session_id, tmux_pane, status FROM sessions
                WHERE tmux_pane IS NOT NULL AND tmux_pane != '';") || return 0
    while IFS='|' read -r sid pane st; do
        [[ -z "$sid" ]] && continue
        # Dead pane → always delete
        if ! printf '%s' "$alive_panes" | grep -qx "$pane"; then
            _debug_log "reap sid=$sid reason=dead_pane"
            sql "DELETE FROM sessions WHERE session_id='$sid';"
            changed=1
        # Live pane, no agent process, working/blocked → delete (Ctrl+C case)
        elif [[ "$st" != "idle" && "$st" != "completed" ]] \
          && ! printf '%s' "$claude_panes" | grep -qx "$pane"; then
            _debug_log "reap sid=$sid reason=no_agent"
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
    _ensure_schema

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
        _has_claude_child "$shell_pid" || continue

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
             (session_id, status, cwd, project_name, git_branch, agent_client, tmux_pane, tmux_target)
             SELECT '$(sql_esc "$sid")', 'idle',
                    '$(sql_esc "$cwd")', '$(sql_esc "$project")',
                    '$(sql_esc "$branch")', 'claude', '$(sql_esc "$pane")',
                    '$(sql_esc "$target")'
             WHERE NOT EXISTS (SELECT 1 FROM sessions WHERE tmux_pane='$(sql_esc "$pane")');"
        changed=1
        _debug_log "scan_detect sid=$sid path=[claude] $cwd pane=$pane"
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
        _load_config_fast
        _debug_log "goto target=$target sid=$_goto_sid via=menu"
        sql "UPDATE sessions SET status='idle', updated_at=unixepoch()
             WHERE session_id='$(sql_esc "$_goto_sid")' AND status='completed';" 2>/dev/null || true
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
    _load_config_fast
    _debug_log "pane_focus pane=$pane_id via=focus"
    sql "UPDATE sessions SET status='idle', updated_at=unixepoch()
         WHERE tmux_pane='$(sql_esc "$pane_id")' AND status='completed';"
    while IFS= read -r _fsid; do
        [[ -z "$_fsid" ]] && continue
        _debug_log "pane_focus_clear sid=$_fsid completed->idle"
        local _fproject
        _fproject=$(sql "SELECT project_name FROM sessions WHERE session_id='$(sql_esc "$_fsid")';") || true
        _fire_transition_hook "completed" "idle" "$_fsid" "$_fproject"
    done <<< "$_focus_sids"
    _render_cache 2>/dev/null || true
    tmux refresh-client -S 2>/dev/null || true
}

# Like pane-focus, but only clears if the user is actually on this pane.
# Called from deferred Stop hook to avoid clearing completed when user is elsewhere.
cmd_pane_focus_if_active() {
    [[ -f "$DB" ]] || return 0
    local pane_id="$1"
    local active_pane
    active_pane=$(tmux display-message -p '#{pane_id}' 2>/dev/null) || return 0
    if [[ "$active_pane" != "$pane_id" ]]; then
        _load_config_fast
        _debug_log "pane_focus_if_active pane=$pane_id active=$active_pane skip=not_focused"
        return 0
    fi
    _load_config_fast
    _debug_log "pane_focus_if_active pane=$pane_id active=$active_pane via=deferred_timer"
    cmd_pane_focus "$pane_id"
}

# ── main ──────────────────────────────────────────────────────────────

case "${1:-}" in
    init)       cmd_init ;;
    hook)       cmd_hook "${2:?Usage: tracker.sh hook <event>}" ;;
    codex-notify) cmd_codex_notify "${@}" ;;
    status-bar) cmd_status_bar ;;
    refresh)    cmd_refresh ;;
    menu)       tmux display-message "Opening..." 2>/dev/null || true; _reap_dead 2>/dev/null || true; cmd_scan 2>/dev/null || true; cmd_menu "${2:-1}" ;;
    goto)       cmd_goto "${2:?Usage: tracker.sh goto <target>}" ;;
    pane-focus) cmd_pane_focus "${2:?Usage: tracker.sh pane-focus <pane_id>}" ;;
    pane-focus-if-active) cmd_pane_focus_if_active "${2:?Usage: tracker.sh pane-focus-if-active <pane_id>}" ;;
    scan)       cmd_scan ;;
    cleanup)    cmd_cleanup ;;
    *)          echo "Usage: tracker.sh {init|hook|codex-notify|status-bar|refresh|menu|scan|cleanup|goto|pane-focus}" >&2
                exit 1 ;;
esac
