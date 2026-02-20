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

@test "Stop sets status to idle" {
    insert_session "s1" "working" "%1"
    _hook_stop "s1" '{}'
    [[ "$(get_status s1)" == "idle" ]]
}

@test "Notification sets working to blocked" {
    insert_session "s1" "working" "%1"
    _hook_notification "s1" '{}'
    [[ "$(get_status s1)" == "blocked" ]]
}

@test "Notification does not change idle to blocked" {
    insert_session "s1" "idle" "%1"
    _hook_notification "s1" '{}'
    [[ "$(get_status s1)" == "idle" ]]
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
    insert_session "old-main" "idle" "%1" ""
    export TMUX_PANE="%1"

    # Mock tmux display-message
    tmux() { echo "test:0.0"; }

    _ensure_session "new-main" '{"cwd":"/tmp/test"}'
    [[ "$(count_sessions)" -eq 1 ]]
    [[ -z "$(get_status old-main)" ]]
    [[ "$(get_status new-main)" == "working" ]]
}

@test "_ensure_session preserves subagent on same pane" {
    insert_session "sub1" "working" "%1" "subagent"
    insert_session "old-main" "idle" "%1" ""
    export TMUX_PANE="%1"

    tmux() { echo "test:0.0"; }

    _ensure_session "new-main" '{"cwd":"/tmp/test"}'
    # subagent preserved, old main evicted
    [[ "$(get_status sub1)" == "working" ]]
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

@test "_reap_dead cleans up sessions when Claude process is gone" {
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

# ── Cache rendering ──────────────────────────────────────────────────

@test "_render_cache produces correct format with no blocked" {
    insert_session "s1" "working" "%1"
    insert_session "s2" "idle" "%2"
    _render_cache
    local out
    out=$(cat "$CACHE")
    [[ "$out" == "#[fg=black]1.#[default] #[fg=black]1*#[default] #[fg=black]0!#[default]" ]]
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

@test "blocked timer no suffix for <1 minute" {
    insert_session "b1" "blocked" "%1"
    # updated_at is now (just inserted), so dur=0
    _render_cache
    local out
    out=$(cat "$CACHE")
    # Should be "1!" with no duration suffix before #[default]
    [[ "$out" =~ 1!#\[default\] ]]
}

# ── cmd_status_bar live timer ────────────────────────────────────────

@test "cmd_status_bar recomputes blocked timer from DB" {
    insert_session "b1" "blocked" "%1"
    insert_session "w1" "working" "%2"

    # Render cache with current time (0m)
    _render_cache

    # Now backdate the blocked session to 10 min ago
    sql "UPDATE sessions SET updated_at = unixepoch() - 600 WHERE session_id='b1';"

    # cmd_status_bar should show live 10m, not the cached 0m
    local out
    out=$(cmd_status_bar)
    [[ "$out" == *"1!10m"* ]]
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

# ── SubagentStart / SubagentStop ─────────────────────────────────────

@test "SubagentStart creates working session with agent_type" {
    _hook_subagent_start "parent" '{"subagent_id":"sub1","subagent_type":"researcher","cwd":"/tmp/test"}'
    [[ "$(get_status sub1)" == "working" ]]
    local atype
    atype=$(sql "SELECT agent_type FROM sessions WHERE session_id='sub1';")
    [[ "$atype" == "researcher" ]]
}

@test "SubagentStop deletes subagent session" {
    insert_session "sub1" "working" "%1" "subagent"
    _hook_subagent_stop '{"subagent_id":"sub1"}'
    [[ "$(count_sessions)" -eq 0 ]]
}

# ── sql_esc ──────────────────────────────────────────────────────────

@test "sql_esc escapes single quotes" {
    run sql_esc "it's a test"
    [[ "$output" == "it''s a test" ]]
}

# ── Idle count stability (no flicker) ──────────────────────────────

@test "SessionStart does not reset working session to idle" {
    insert_session "s1" "working" "%1"
    # Simulate time passing so updated_at != started_at
    sql "UPDATE sessions SET updated_at = unixepoch() + 5 WHERE session_id='s1';"
    _hook_session_start "s1" '{}'
    [[ "$(get_status s1)" == "working" ]]
}

@test "SessionStart sets idle only for freshly created sessions" {
    insert_session "s1" "working" "%1"
    # Fresh session: updated_at == started_at (default from insert)
    _hook_session_start "s1" '{}'
    [[ "$(get_status s1)" == "idle" ]]
}

@test "atomic eviction keeps count stable during pane takeover" {
    insert_session "old" "idle" "%1" ""
    insert_session "other" "idle" "%2" ""
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
