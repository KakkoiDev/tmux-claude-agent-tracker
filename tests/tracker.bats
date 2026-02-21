#!/usr/bin/env bats

load helpers

setup() {
    setup_test_env
    source_tracker_functions
}

teardown() {
    teardown_test_env
}

# ── Hook state transitions ───────────────────────────────────────────

@test "UserPromptSubmit sets status to working" {
    insert_session "s1" "idle" "%1"
    _hook_prompt "s1"
    [[ "$(get_status s1)" == "working" ]]
}

@test "Stop sets working to completed" {
    insert_session "s1" "working" "%1"
    _hook_stop "s1"
    [[ "$(get_status s1)" == "completed" ]]
}

@test "Stop sets blocked to completed" {
    insert_session "s1" "blocked" "%1"
    _hook_stop "s1"
    [[ "$(get_status s1)" == "completed" ]]
}

@test "Stop on idle is no-op" {
    insert_session "s1" "idle" "%1"
    _hook_stop "s1"
    [[ "$(get_status s1)" == "idle" ]]
}

@test "Stop on completed is no-op" {
    insert_session "s1" "completed" "%1"
    local before
    before=$(sql "SELECT updated_at FROM sessions WHERE session_id='s1';")
    _hook_stop "s1"
    [[ "$(get_status s1)" == "completed" ]]
    local after
    after=$(sql "SELECT updated_at FROM sessions WHERE session_id='s1';")
    [[ "$before" == "$after" ]]
}

@test "Stop on active pane sets idle instead of completed" {
    insert_session "s1" "working" "%1"
    export TMUX_PANE="%1"
    tmux() {
        if [[ "${1:-}" == "display-message" && "$*" == *"pane_active"* ]]; then
            echo "1"
            return 0
        fi
        return 0
    }
    _hook_stop "s1"
    [[ "$(get_status s1)" == "idle" ]]
}

@test "Stop on inactive pane sets completed" {
    insert_session "s1" "working" "%1"
    export TMUX_PANE="%1"
    tmux() {
        if [[ "${1:-}" == "display-message" && "$*" == *"pane_active"* ]]; then
            echo "0"
            return 0
        fi
        return 0
    }
    _hook_stop "s1"
    [[ "$(get_status s1)" == "completed" ]]
}

@test "Stop without TMUX_PANE sets completed" {
    insert_session "s1" "working" "%1"
    export TMUX_PANE=""
    _hook_stop "s1"
    [[ "$(get_status s1)" == "completed" ]]
}

@test "Notification sets working to blocked" {
    insert_session "s1" "working" "%1"
    _hook_notification "s1" '{}'
    [[ "$(get_status s1)" == "blocked" ]]
}

@test "Notification permission_prompt sets working to blocked" {
    insert_session "s1" "working" "%1"
    __json='{"session_id":"s1","notification_type":"permission_prompt"}'
    _hook_notification "s1"
    [[ "$(get_status s1)" == "blocked" ]]
}

@test "Notification idle_prompt does not set blocked" {
    insert_session "s1" "working" "%1"
    __json='{"session_id":"s1","notification_type":"idle_prompt"}'
    _hook_notification "s1"
    [[ "$(get_status s1)" == "working" ]]
}

@test "Notification auth_success does not set blocked" {
    insert_session "s1" "working" "%1"
    __json='{"session_id":"s1","notification_type":"auth_success"}'
    _hook_notification "s1"
    [[ "$(get_status s1)" == "working" ]]
}

@test "PostToolUseFailure transitions blocked to working" {
    insert_session "s1" "blocked" "%1"
    _hook_post_tool "s1"
    [[ "$(get_status s1)" == "working" ]]
}

@test "Notification does not set idle to blocked" {
    insert_session "s1" "idle" "%1"
    _hook_notification "s1" '{}'
    [[ "$(get_status s1)" == "idle" ]]
}

@test "Notification after Stop does not re-block session" {
    insert_session "s1" "working" "%1"
    _hook_stop "s1"
    [[ "$(get_status s1)" == "completed" ]]
    _hook_notification "s1" '{}'
    [[ "$(get_status s1)" == "completed" ]]
    _render_cache
    [[ "$(cat "$CACHE")" == *"1+"* ]]
    [[ "$(cat "$CACHE")" == *"0!"* ]]
}

@test "Notification does not reset blocked timer" {
    insert_session "s1" "blocked" "%1"
    sql "UPDATE sessions SET updated_at = unixepoch() - 300 WHERE session_id='s1';"
    _hook_notification "s1" '{}'
    local ts
    ts=$(sql "SELECT updated_at FROM sessions WHERE session_id='s1';")
    # updated_at should still be ~300s ago, not reset
    [[ "$ts" -lt "$(( $(date +%s) - 200 ))" ]]
}

@test "PostToolUse sets non-working to working" {
    insert_session "s1" "idle" "%1"
    _hook_post_tool "s1" '{}'
    [[ "$(get_status s1)" == "working" ]]
}

@test "PostToolUse keeps working as working" {
    insert_session "s1" "working" "%1"
    _hook_post_tool "s1" '{}'
    [[ "$(get_status s1)" == "working" ]]
}

@test "TeammateIdle sets status to idle" {
    insert_session "t1" "working" "%1"
    _hook_teammate_idle '{"teammate_id":"t1"}'
    [[ "$(get_status t1)" == "idle" ]]
}

# ── SessionEnd cleanup ───────────────────────────────────────────────

@test "SessionEnd deletes the session" {
    insert_session "s1" "working" "%1"
    sql "DELETE FROM sessions WHERE session_id='s1';"
    [[ "$(count_sessions)" -eq 0 ]]
}

# ── Subagent preservation ────────────────────────────────────────────

@test "_ensure_session evicts stale main session on same pane" {
    insert_session "old-main" "idle" "%1"
    export TMUX_PANE="%1"

    # Mock tmux display-message
    tmux() { echo "test:0.0"; }

    _ensure_session "new-main" '{"cwd":"/tmp/test"}'
    [[ "$(count_sessions)" -eq 1 ]]
    [[ -z "$(get_status old-main)" ]]
    [[ "$(get_status new-main)" == "working" ]]
}

# ── Scan deduplication ───────────────────────────────────────────────

@test "scan conditional INSERT skips when hook entry owns pane" {
    insert_session "hook-s1" "working" "%5"
    # Simulate what scan does: conditional insert
    sql "INSERT INTO sessions
         (session_id, status, cwd, project_name, tmux_pane)
         SELECT 'scan-%5', 'idle', '/tmp/test', 'test', '%5'
         WHERE NOT EXISTS (SELECT 1 FROM sessions WHERE tmux_pane='%5');"
    [[ "$(count_sessions)" -eq 1 ]]
    [[ "$(get_status hook-s1)" == "working" ]]
}

@test "scan conditional INSERT succeeds when no session owns pane" {
    sql "INSERT INTO sessions
         (session_id, status, cwd, project_name, tmux_pane)
         SELECT 'scan-%6', 'idle', '/tmp/test', 'test', '%6'
         WHERE NOT EXISTS (SELECT 1 FROM sessions WHERE tmux_pane='%6');"
    [[ "$(count_sessions)" -eq 1 ]]
    [[ "$(get_status 'scan-%6')" == "idle" ]]
}

# ── Reap dead logic ─────────────────────────────────────────────────

@test "_reap_dead removes sessions with dead panes" {
    insert_session "s1" "working" "%99"
    insert_session "s2" "idle" "%100"

    # Mock: only %99 is alive with claude running
    tmux() {
        case "$1" in
            list-panes) echo "%99 1234" ;;
            *) true ;;
        esac
    }
    pgrep() { return 0; }

    _reap_dead
    [[ "$(get_status s1)" == "working" ]]
    [[ -z "$(get_status s2)" ]]
}

@test "_reap_dead keeps sessions with live panes and claude process" {
    insert_session "s1" "working" "%10"
    insert_session "s2" "idle" "%11"

    tmux() {
        case "$1" in
            list-panes) printf '%s\n' "%10 1234" "%11 5678" ;;
            *) true ;;
        esac
    }
    pgrep() { return 0; }

    _reap_dead
    [[ "$(count_sessions)" -eq 2 ]]
}

@test "_reap_dead skips sessions without tmux_pane" {
    insert_session "s-nopane" "working" ""

    tmux() {
        case "$1" in
            list-panes) echo "%10 1234" ;;
            *) true ;;
        esac
    }
    pgrep() { return 0; }

    _reap_dead
    [[ "$(count_sessions)" -eq 1 ]]
}

@test "_reap_dead cleans up working sessions when Claude process is gone" {
    insert_session "s1" "working" "%10"

    # Mock: pane %10 is alive but no claude child process
    tmux() {
        case "$1" in
            list-panes) echo "%10 1234" ;;
            *) true ;;
        esac
    }
    pgrep() { return 1; }

    _reap_dead
    [[ -z "$(get_status s1)" ]]
    [[ "$(count_sessions)" -eq 0 ]]
}

@test "_reap_dead removes stale paneless sessions" {
    insert_session "no-pane" "working" ""
    # Backdate to 11 minutes ago (threshold is 10 min)
    sql "UPDATE sessions SET updated_at = unixepoch() - 660 WHERE session_id='no-pane';"

    insert_session "fresh-no-pane" "working" ""
    # This one is recent — should survive

    tmux() {
        case "$1" in
            list-panes) echo "%10 1234" ;;
            *) true ;;
        esac
    }
    pgrep() { return 0; }

    _reap_dead
    [[ -z "$(get_status no-pane)" ]]
    [[ "$(get_status fresh-no-pane)" == "working" ]]
}

@test "_reap_dead throttle prevents second call within 30s" {
    insert_session "s1" "working" "%99"

    tmux() {
        case "$1" in
            list-panes) echo "%99 1234" ;;
            *) true ;;
        esac
    }
    pgrep() { return 0; }

    _reap_dead
    [[ -f "$TRACKER_DIR/.last_reap" ]]

    # Insert a dead-pane session after first reap
    insert_session "s2" "working" "%200"

    # Second call within 30s should be throttled — s2 survives
    _reap_dead
    [[ "$(get_status s2)" == "working" ]]
}

@test "_reap_dead keeps idle sessions even without claude process" {
    insert_session "s1" "idle" "%10"

    tmux() {
        case "$1" in
            list-panes) echo "%10 1234" ;;
            *) true ;;
        esac
    }
    pgrep() { return 1; }

    _reap_dead
    [[ "$(get_status s1)" == "idle" ]]
}

# ── Cache rendering ──────────────────────────────────────────────────

@test "_render_cache produces correct format with no blocked" {
    insert_session "s1" "working" "%1"
    insert_session "s2" "idle" "%2"
    _render_cache
    local out
    out=$(cat "$CACHE")
    [[ "$out" == "#[fg=black]1.#[default] #[fg=black]1*#[default] #[fg=black]0+#[default] #[fg=black]0!#[default]" ]]
}

@test "_render_cache produces correct format with blocked" {
    insert_session "s1" "blocked" "%1"
    # Set updated_at to ~5 minutes ago
    sql "UPDATE sessions SET updated_at = unixepoch() - 300 WHERE session_id='s1';"
    _render_cache
    local out
    out=$(cat "$CACHE")
    # Should contain "1!5m" (approximately)
    [[ "$out" == *"1!"* ]]
    [[ "$out" == *"m#[default]"* ]]
}

@test "_render_cache counts multiple statuses correctly" {
    insert_session "w1" "working" "%1"
    insert_session "w2" "working" "%2"
    insert_session "i1" "idle" "%3"
    insert_session "i2" "idle" "%4"
    insert_session "i3" "idle" "%5"
    insert_session "b1" "blocked" "%6"
    _render_cache
    local out
    out=$(cat "$CACHE")
    # 3 idle, 2 working, 1 blocked
    [[ "$out" == *"3."* ]]
    [[ "$out" == *"2*"* ]]
    [[ "$out" == *"1!"* ]]
}

# ── Blocked timer ────────────────────────────────────────────────────

@test "blocked timer shows minutes" {
    insert_session "b1" "blocked" "%1"
    sql "UPDATE sessions SET updated_at = unixepoch() - 180 WHERE session_id='b1';"
    _render_cache
    local out
    out=$(cat "$CACHE")
    [[ "$out" == *"1!3m"* ]]
}

@test "blocked timer shows hours for 60+ minutes" {
    insert_session "b1" "blocked" "%1"
    sql "UPDATE sessions SET updated_at = unixepoch() - 7200 WHERE session_id='b1';"
    _render_cache
    local out
    out=$(cat "$CACHE")
    [[ "$out" == *"1!2h"* ]]
}

@test "SHOW_PROJECT=1 includes project name in cache" {
    export SHOW_PROJECT="1"
    insert_session "s1" "working" "%1"
    sql "UPDATE sessions SET project_name='myapp' WHERE session_id='s1';"
    _render_cache
    local out
    out=$(cat "$CACHE")
    [[ "$out" == *"@myapp"* ]]
}

@test "SHOW_PROJECT=0 omits project name from cache" {
    export SHOW_PROJECT="0"
    insert_session "s1" "working" "%1"
    sql "UPDATE sessions SET project_name='myapp' WHERE session_id='s1';"
    _render_cache
    local out
    out=$(cat "$CACHE")
    [[ "$out" != *"@myapp"* ]]
}

@test "SHOW_PROJECT prefers blocked session project" {
    export SHOW_PROJECT="1"
    insert_session "s1" "working" "%1"
    sql "UPDATE sessions SET project_name='working-proj' WHERE session_id='s1';"
    insert_session "s2" "blocked" "%2"
    sql "UPDATE sessions SET project_name='blocked-proj' WHERE session_id='s2';"
    _render_cache
    local out
    out=$(cat "$CACHE")
    [[ "$out" == *"@blocked-proj"* ]]
}

@test "blocked timer no suffix for <1 minute" {
    insert_session "b1" "blocked" "%1"
    # updated_at is now (just inserted), so dur=0
    _render_cache
    local out
    out=$(cat "$CACHE")
    # Should be "1!" with no duration suffix before #[default]
    [[ "$out" =~ 1!#\[default\] ]]
}

# ── Cache lifecycle (hot-path render) ────────────────────────────────

@test "PostToolUse updates cache when transitioning blocked to working" {
    insert_session "s1" "blocked" "%1"
    _render_cache
    local before
    before=$(cat "$CACHE")
    [[ "$before" == *"1!"* ]]

    _hook_post_tool "s1"
    [[ "$(get_status s1)" == "working" ]]
    # __render was set — _write_cache should have been called by cmd_hook
    # but since we call _hook_post_tool directly, we must verify __render
    [[ -n "$__render" ]]
    _load_config_fast
    _write_cache "$__render"
    local after
    after=$(cat "$CACHE")
    [[ "$after" == *"1*"* ]]
    [[ "$after" == *"0!"* ]]
}

@test "Notification updates cache when transitioning working to blocked" {
    insert_session "s1" "working" "%1"
    _render_cache
    local before
    before=$(cat "$CACHE")
    [[ "$before" == *"1*"* ]]

    _hook_notification "s1"
    [[ "$(get_status s1)" == "blocked" ]]
    [[ -n "$__render" ]]
    _load_config_fast
    _write_cache "$__render"
    local after
    after=$(cat "$CACHE")
    [[ "$after" == *"1!"* ]]
    [[ "$after" == *"0*"* ]]
}

@test "Stop clears blocked from cache" {
    insert_session "s1" "blocked" "%1"
    _render_cache
    [[ "$(cat "$CACHE")" == *"1!"* ]]

    _hook_stop "s1"
    _render_cache
    local after
    after=$(cat "$CACHE")
    [[ "$after" == *"1+"* ]]
    [[ "$after" == *"0!"* ]]
}

@test "SessionEnd clears all counts from cache" {
    insert_session "s1" "blocked" "%1"
    _render_cache
    [[ "$(cat "$CACHE")" == *"1!"* ]]

    sql "DELETE FROM sessions WHERE session_id='s1';"
    _render_cache
    local after
    after=$(cat "$CACHE")
    [[ "$after" == *"0."* ]]
    [[ "$after" == *"0*"* ]]
    [[ "$after" == *"0!"* ]]
}

@test "full lifecycle: blocked -> PostToolUse -> Stop -> cache is clean" {
    insert_session "s1" "blocked" "%1"
    _render_cache
    [[ "$(cat "$CACHE")" == *"1!"* ]]

    # Transition blocked -> working via PostToolUse
    __changed=1
    __render=""
    _hook_post_tool "s1"
    [[ -n "$__render" ]]
    _load_config_fast
    _write_cache "$__render"
    [[ "$(cat "$CACHE")" == *"1*"* ]]
    [[ "$(cat "$CACHE")" == *"0!"* ]]

    # Stop -> completed
    _hook_stop "s1"
    _render_cache
    [[ "$(cat "$CACHE")" == *"1+"* ]]
    [[ "$(cat "$CACHE")" == *"0!"* ]]

    # SessionEnd -> deleted
    sql "DELETE FROM sessions WHERE session_id='s1';"
    _render_cache
    [[ "$(cat "$CACHE")" == *"0."* ]]
    [[ "$(cat "$CACHE")" == *"0*"* ]]
    [[ "$(cat "$CACHE")" == *"0!"* ]]
}

# ── cmd_status_bar live timer ────────────────────────────────────────

@test "cmd_status_bar is a pure cache read" {
    insert_session "b1" "blocked" "%1"
    insert_session "w1" "working" "%2"

    # Render cache with current time (0m)
    _render_cache
    local cached
    cached=$(cat "$CACHE")

    # Backdate the blocked session — status-bar should NOT recompute
    sql "UPDATE sessions SET updated_at = unixepoch() - 600 WHERE session_id='b1';"

    local out
    out=$(cmd_status_bar)
    [[ "$out" == "$cached" ]]
}

@test "cmd_status_bar returns cached output when no blocked" {
    insert_session "w1" "working" "%1"
    insert_session "i1" "idle" "%2"
    _render_cache
    local expected
    expected=$(cat "$CACHE")
    local out
    out=$(cmd_status_bar)
    [[ "$out" == "$expected" ]]
}

# ── sql_esc ──────────────────────────────────────────────────────────

@test "sql_esc escapes single quotes" {
    run sql_esc "it's a test"
    [[ "$output" == "it''s a test" ]]
}

@test "escaped session_id does not match other sessions" {
    insert_session "normal" "working" "%1"
    # Session ID with SQL injection attempt
    local evil="x'; DELETE FROM sessions;--"
    _hook_prompt "$(sql_esc "$evil")"
    # normal session untouched, evil session not found
    [[ "$(get_status normal)" == "working" ]]
    [[ "$(count_sessions)" -eq 1 ]]
}

# ── Idle count stability (no flicker) ──────────────────────────────

@test "SessionStart on existing working session is no-op" {
    insert_session "s1" "working" "%1"
    export TMUX_PANE="%1"
    tmux() { echo "test:0.0"; }
    _ensure_session "s1" '{"cwd":"/tmp/test"}' "idle"
    # Fast path: session exists with pane info, no change
    [[ "$(get_status s1)" == "working" ]]
}

# ── _json_val ────────────────────────────────────────────────────────

@test "_json_val extracts simple string value" {
    local result
    result=$(_json_val '{"session_id":"abc123","cwd":"/tmp"}' "session_id")
    [[ "$result" == "abc123" ]]
}

@test "_json_val returns empty for missing key" {
    local result
    result=$(_json_val '{"session_id":"abc123"}' "cwd")
    [[ -z "$result" ]]
}

@test "_json_val extracts correct key among many" {
    local json='{"subagent_id":"sub1","subagent_type":"researcher","cwd":"/tmp/test"}'
    [[ "$(_json_val "$json" "subagent_id")" == "sub1" ]]
    [[ "$(_json_val "$json" "subagent_type")" == "researcher" ]]
    [[ "$(_json_val "$json" "cwd")" == "/tmp/test" ]]
}

@test "_json_val returns empty on empty input" {
    local result
    result=$(_json_val '{}' "session_id")
    [[ -z "$result" ]]
}

@test "_json_val handles keys with dots" {
    local json='{"a.b":"dot","ab":"nodot"}'
    [[ "$(_json_val "$json" "a.b")" == "dot" ]]
}

@test "_json_val does not match partial key via dot wildcard" {
    # With regex impl, "a.b" would match "axb" as dot is any-char
    local json='{"axb":"wrong","a.b":"right"}'
    [[ "$(_json_val "$json" "a.b")" == "right" ]]
}

# ── stdin handling (read -r regression) ──────────────────────────────

@test "cmd_hook works with JSON lacking trailing newline" {
    insert_session "s1" "working" "%1"
    # printf sends JSON without trailing newline — must not be silently dropped
    printf '{"session_id":"s1"}' | cmd_hook "Stop"
    [[ "$(get_status s1)" == "completed" ]]
}

@test "cmd_hook works with JSON having trailing newline" {
    insert_session "s1" "working" "%1"
    echo '{"session_id":"s1"}' | cmd_hook "Stop"
    [[ "$(get_status s1)" == "completed" ]]
}

@test "cmd_hook exits cleanly on empty stdin" {
    insert_session "s1" "working" "%1"
    echo "" | cmd_hook "PostToolUse"
    # Session unchanged — empty JSON has no session_id
    [[ "$(get_status s1)" == "working" ]]
}

# ── No-op skip (SELECT changes) ─────────────────────────────────────

@test "PostToolUse no-op does not update timestamp" {
    insert_session "s1" "working" "%1"
    sql "UPDATE sessions SET updated_at = unixepoch() - 100 WHERE session_id='s1';"
    local before
    before=$(sql "SELECT updated_at FROM sessions WHERE session_id='s1';")
    _hook_post_tool "s1" '{}'
    local after
    after=$(sql "SELECT updated_at FROM sessions WHERE session_id='s1';")
    [[ "$before" == "$after" ]]
}

@test "Notification no-op does not update timestamp" {
    insert_session "s1" "blocked" "%1"
    sql "UPDATE sessions SET updated_at = unixepoch() - 100 WHERE session_id='s1';"
    local before
    before=$(sql "SELECT updated_at FROM sessions WHERE session_id='s1';")
    _hook_notification "s1" '{}'
    local after
    after=$(sql "SELECT updated_at FROM sessions WHERE session_id='s1';")
    [[ "$before" == "$after" ]]
}

# ── Idle count stability (no flicker) ──────────────────────────────

# ── Instant push via tmux option ─────────────────────────────────────

@test "_write_cache sets tmux option @claude-tracker-status" {
    local tmux_set_value=""
    tmux() {
        if [[ "${1:-}" == "set" && "${2:-}" == "-gq" && "${3:-}" == "@claude-tracker-status" ]]; then
            tmux_set_value="${4:-}"
        fi
        return 0
    }

    insert_session "s1" "working" "%1"
    _render_cache
    [[ -n "$tmux_set_value" ]]
    [[ "$tmux_set_value" == *"1*"* ]]
}

@test "cmd_refresh produces no stdout" {
    insert_session "s1" "working" "%1"
    local out
    out=$(cmd_refresh)
    [[ -z "$out" ]]
}

@test "cmd_refresh updates cache file" {
    insert_session "s1" "blocked" "%1"
    sql "UPDATE sessions SET updated_at = unixepoch() - 300 WHERE session_id='s1';"
    cmd_refresh
    [[ -f "$CACHE" ]]
    [[ "$(cat "$CACHE")" == *"1!"* ]]
    [[ "$(cat "$CACHE")" == *"5m"* ]]
}

@test "cmd_refresh is no-op without DB" {
    rm -f "$DB"
    local out
    out=$(cmd_refresh)
    [[ -z "$out" ]]
}

@test "atomic eviction keeps count stable during pane takeover" {
    insert_session "old" "idle" "%1"
    insert_session "other" "idle" "%2"
    export TMUX_PANE="%1"
    tmux() { echo "test:0.0"; }

    _ensure_session "new" '{"cwd":"/tmp/test"}'
    # Total count should be 2 (old evicted, new created, other untouched)
    # Never drops to 1 between DELETE and INSERT
    [[ "$(count_sessions)" -eq 2 ]]
    [[ -z "$(get_status old)" ]]
    [[ "$(get_status new)" == "working" ]]
    [[ "$(get_status other)" == "idle" ]]
}

# ── Integration tests (full cmd_hook pipeline via stdin) ──────────────

# Mock that handles all tmux subcommands correctly for integration tests.
# _reap_dead calls list-panes and pgrep, so we need both.
_integration_mock() {
    local pane="${1:-%1}"
    export TMUX_PANE="$pane"
    tmux() {
        case "$1" in
            display-message) echo "test:0.0" ;;
            list-panes) echo "$TMUX_PANE 1234" ;;
            *) true ;;
        esac
    }
    pgrep() { return 0; }
}

@test "integration: SessionStart creates idle session" {
    _integration_mock "%1"
    echo '{"session_id":"s1","cwd":"/tmp/test"}' | cmd_hook "SessionStart"
    [[ "$(get_status s1)" == "idle" ]]
}

@test "integration: SessionStart then UserPromptSubmit sets working" {
    _integration_mock "%1"
    echo '{"session_id":"s1","cwd":"/tmp/test"}' | cmd_hook "SessionStart"
    [[ "$(get_status s1)" == "idle" ]]
    echo '{"session_id":"s1"}' | cmd_hook "UserPromptSubmit"
    [[ "$(get_status s1)" == "working" ]]
}

@test "integration: full lifecycle Start -> Prompt -> PostToolUse -> Stop -> End" {
    _integration_mock "%1"
    echo '{"session_id":"s1","cwd":"/tmp/test"}' | cmd_hook "SessionStart"
    [[ "$(get_status s1)" == "idle" ]]

    echo '{"session_id":"s1"}' | cmd_hook "UserPromptSubmit"
    [[ "$(get_status s1)" == "working" ]]

    echo '{"session_id":"s1","tool_name":"Read"}' | cmd_hook "PostToolUse"
    [[ "$(get_status s1)" == "working" ]]

    echo '{"session_id":"s1"}' | cmd_hook "Stop"
    [[ "$(get_status s1)" == "completed" ]]

    echo '{"session_id":"s1"}' | cmd_hook "SessionEnd"
    [[ "$(count_sessions)" -eq 0 ]]
}

@test "integration: Notification permission_prompt sets blocked" {
    insert_session "s1" "working" "%1"
    echo '{"session_id":"s1","notification_type":"permission_prompt"}' | cmd_hook "Notification"
    [[ "$(get_status s1)" == "blocked" ]]
}

@test "integration: Notification elicitation_dialog sets blocked" {
    insert_session "s1" "working" "%1"
    echo '{"session_id":"s1","notification_type":"elicitation_dialog"}' | cmd_hook "Notification"
    [[ "$(get_status s1)" == "blocked" ]]
}

@test "integration: blocked then PostToolUse sets working" {
    insert_session "s1" "blocked" "%1"
    echo '{"session_id":"s1","tool_name":"Read"}' | cmd_hook "PostToolUse"
    [[ "$(get_status s1)" == "working" ]]
}

@test "integration: blocked then PostToolUseFailure sets working" {
    insert_session "s1" "blocked" "%1"
    echo '{"session_id":"s1","tool_name":"Bash"}' | cmd_hook "PostToolUseFailure"
    [[ "$(get_status s1)" == "working" ]]
}

@test "integration: blocked then UserPromptSubmit sets working" {
    _integration_mock "%1"
    insert_session "s1" "blocked" "%1"
    echo '{"session_id":"s1"}' | cmd_hook "UserPromptSubmit"
    [[ "$(get_status s1)" == "working" ]]
}

@test "integration: blocked then Stop sets completed" {
    insert_session "s1" "blocked" "%1"
    echo '{"session_id":"s1"}' | cmd_hook "Stop"
    [[ "$(get_status s1)" == "completed" ]]
}

@test "integration: idle then PostToolUse sets working" {
    insert_session "s1" "idle" "%1"
    echo '{"session_id":"s1","tool_name":"Read"}' | cmd_hook "PostToolUse"
    [[ "$(get_status s1)" == "working" ]]
}

@test "integration: Notification idle_prompt does not block" {
    insert_session "s1" "working" "%1"
    echo '{"session_id":"s1","notification_type":"idle_prompt"}' | cmd_hook "Notification"
    [[ "$(get_status s1)" == "working" ]]
}

@test "integration: repeated Notification does not reset timer" {
    insert_session "s1" "blocked" "%1"
    sql "UPDATE sessions SET updated_at = unixepoch() - 300 WHERE session_id='s1';"
    local before
    before=$(sql "SELECT updated_at FROM sessions WHERE session_id='s1';")
    echo '{"session_id":"s1","notification_type":"permission_prompt"}' | cmd_hook "Notification"
    local after
    after=$(sql "SELECT updated_at FROM sessions WHERE session_id='s1';")
    [[ "$before" == "$after" ]]
}

@test "integration: SessionStart on existing working session is no-op" {
    _integration_mock "%1"
    insert_session "s1" "working" "%1"
    echo '{"session_id":"s1","cwd":"/tmp/test"}' | cmd_hook "SessionStart"
    [[ "$(get_status s1)" == "working" ]]
}

@test "integration: pane takeover evicts old session" {
    _integration_mock "%1"
    insert_session "old" "idle" "%1"
    echo '{"session_id":"new","cwd":"/tmp/test"}' | cmd_hook "SessionStart"
    [[ -z "$(get_status old)" ]]
    [[ "$(get_status new)" == "idle" ]]
}

# ── Completed status tests ──────────────────────────────────────────

@test "goto clears completed to idle" {
    insert_session "s1" "completed" "%1"
    sql "UPDATE sessions SET tmux_target='test:0.0' WHERE session_id='s1';"
    cmd_goto "test:0.0"
    [[ "$(get_status s1)" == "idle" ]]
}

@test "goto does not change non-completed sessions" {
    insert_session "s1" "working" "%1"
    sql "UPDATE sessions SET tmux_target='test:0.0' WHERE session_id='s1';"
    cmd_goto "test:0.0"
    [[ "$(get_status s1)" == "working" ]]
}

@test "completed → UserPromptSubmit → working" {
    insert_session "s1" "completed" "%1"
    _hook_prompt "s1"
    [[ "$(get_status s1)" == "working" ]]
}

@test "completed → PostToolUse → working" {
    insert_session "s1" "completed" "%1"
    _hook_post_tool "s1"
    [[ "$(get_status s1)" == "working" ]]
}

@test "_render_cache counts completed correctly" {
    insert_session "w1" "working" "%1"
    insert_session "c1" "completed" "%2"
    insert_session "c2" "completed" "%3"
    insert_session "i1" "idle" "%4"
    _render_cache
    local out
    out=$(cat "$CACHE")
    [[ "$out" == *"1."* ]]    # 1 idle
    [[ "$out" == *"1*"* ]]    # 1 working
    [[ "$out" == *"2+"* ]]    # 2 completed
    [[ "$out" == *"0!"* ]]    # 0 blocked
}

@test "_reap_dead preserves completed sessions" {
    insert_session "s1" "completed" "%10"

    tmux() {
        case "$1" in
            list-panes) echo "%10 1234" ;;
            *) true ;;
        esac
    }
    pgrep() { return 1; }

    _reap_dead
    [[ "$(get_status s1)" == "completed" ]]
}

@test "Notification does not set completed to blocked" {
    insert_session "s1" "completed" "%1"
    _hook_notification "s1" '{}'
    [[ "$(get_status s1)" == "completed" ]]
}

# ── Pane focus ───────────────────────────────────────────────────────

@test "cmd_pane_focus clears completed to idle" {
    insert_session "s1" "completed" "%1"
    cmd_pane_focus "%1"
    [[ "$(get_status s1)" == "idle" ]]
}

@test "cmd_pane_focus is no-op for non-completed sessions" {
    insert_session "s1" "working" "%1"
    insert_session "s2" "idle" "%2"
    insert_session "s3" "blocked" "%3"
    cmd_pane_focus "%1"
    cmd_pane_focus "%2"
    cmd_pane_focus "%3"
    [[ "$(get_status s1)" == "working" ]]
    [[ "$(get_status s2)" == "idle" ]]
    [[ "$(get_status s3)" == "blocked" ]]
}

@test "cmd_pane_focus is no-op when no DB" {
    rm -f "$DB"
    run cmd_pane_focus "%1"
    [[ "$status" -eq 0 ]]
}

@test "integration: Stop sets completed then goto clears to idle" {
    _integration_mock "%1"
    echo '{"session_id":"s1","cwd":"/tmp/test"}' | cmd_hook "SessionStart"
    echo '{"session_id":"s1"}' | cmd_hook "UserPromptSubmit"
    [[ "$(get_status s1)" == "working" ]]

    echo '{"session_id":"s1"}' | cmd_hook "Stop"
    [[ "$(get_status s1)" == "completed" ]]

    # Simulate goto — need tmux_target set
    sql "UPDATE sessions SET tmux_target='test:0.0' WHERE session_id='s1';"
    cmd_goto "test:0.0"
    [[ "$(get_status s1)" == "idle" ]]
}

@test "integration: full lifecycle with completed" {
    _integration_mock "%1"
    echo '{"session_id":"s1","cwd":"/tmp/test"}' | cmd_hook "SessionStart"
    [[ "$(get_status s1)" == "idle" ]]

    echo '{"session_id":"s1"}' | cmd_hook "UserPromptSubmit"
    [[ "$(get_status s1)" == "working" ]]

    echo '{"session_id":"s1"}' | cmd_hook "Stop"
    [[ "$(get_status s1)" == "completed" ]]

    # New prompt resumes from completed
    echo '{"session_id":"s1"}' | cmd_hook "UserPromptSubmit"
    [[ "$(get_status s1)" == "working" ]]

    echo '{"session_id":"s1"}' | cmd_hook "Stop"
    [[ "$(get_status s1)" == "completed" ]]

    echo '{"session_id":"s1"}' | cmd_hook "SessionEnd"
    [[ "$(count_sessions)" -eq 0 ]]
}
