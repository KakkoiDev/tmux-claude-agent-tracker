#!/usr/bin/env bats

load integration_helpers

setup() {
    setup_integration
}

teardown() {
    teardown_integration
}

# ── 1. Full lifecycle ────────────────────────────────────────────────

@test "integration: full lifecycle start→prompt→block→unblock→stop→end" {
    local sid="lifecycle-1"
    local json="{\"session_id\":\"$sid\",\"cwd\":\"/tmp/test\"}"

    # SessionStart → idle (fresh session)
    fire_hook SessionStart "$json"
    [[ "$(get_status "$sid")" == "idle" ]]

    # UserPromptSubmit → working
    fire_hook UserPromptSubmit "$json"
    [[ "$(get_status "$sid")" == "working" ]]
    [[ "$(read_cache)" == *"1*"* ]]

    # Notification → blocked
    fire_hook Notification "$json"
    [[ "$(get_status "$sid")" == "blocked" ]]
    [[ "$(read_cache)" == *"1!"* ]]

    # PostToolUse → working (unblock)
    fire_hook PostToolUse "$json"
    [[ "$(get_status "$sid")" == "working" ]]
    [[ "$(read_cache)" == *"1*"* ]]

    # Stop → idle
    fire_hook Stop "$json"
    [[ "$(get_status "$sid")" == "idle" ]]

    # SessionEnd → deleted
    fire_hook SessionEnd "$json"
    [[ "$(count_sessions)" -eq 0 ]]
}

# ── 2. Block transitions ────────────────────────────────────────────

@test "integration: working→blocked→working cycle updates cache" {
    local sid="block-cycle"
    local json="{\"session_id\":\"$sid\",\"cwd\":\"/tmp/test\"}"

    fire_hook SessionStart "$json"
    fire_hook UserPromptSubmit "$json"
    [[ "$(get_status "$sid")" == "working" ]]

    # Block
    fire_hook Notification "$json"
    [[ "$(get_status "$sid")" == "blocked" ]]
    local blocked_cache
    blocked_cache=$(read_cache)
    [[ "$blocked_cache" == *"1!"* ]]

    # Unblock
    fire_hook PostToolUse "$json"
    [[ "$(get_status "$sid")" == "working" ]]
    local working_cache
    working_cache=$(read_cache)
    [[ "$working_cache" == *"0!"* ]]
}

# ── 3. No-op detection ──────────────────────────────────────────────

@test "integration: PostToolUse on working session is no-op" {
    local sid="noop-tool"
    local json="{\"session_id\":\"$sid\",\"cwd\":\"/tmp/test\"}"

    fire_hook SessionStart "$json"
    fire_hook UserPromptSubmit "$json"
    [[ "$(get_status "$sid")" == "working" ]]

    # Record cache mtime
    sleep 1
    local before
    before=$(cache_mtime)

    # PostToolUse while already working — no-op
    sleep 1
    fire_hook PostToolUse "$json"
    local after
    after=$(cache_mtime)

    [[ "$before" == "$after" ]]
}

@test "integration: Notification on blocked session is no-op" {
    local sid="noop-notif"
    local json="{\"session_id\":\"$sid\",\"cwd\":\"/tmp/test\"}"

    fire_hook SessionStart "$json"
    fire_hook UserPromptSubmit "$json"
    fire_hook Notification "$json"
    [[ "$(get_status "$sid")" == "blocked" ]]

    sleep 1
    local before
    before=$(cache_mtime)

    # Notification while already blocked — no-op
    sleep 1
    fire_hook Notification "$json"
    local after
    after=$(cache_mtime)

    [[ "$before" == "$after" ]]
}

# ── 4. Blocked timer ────────────────────────────────────────────────

@test "integration: blocked timer shows minutes" {
    local sid1="timer-min-1"
    local sid2="timer-min-2"

    fire_hook SessionStart "{\"session_id\":\"$sid1\",\"cwd\":\"/tmp/test\"}"
    fire_hook UserPromptSubmit "{\"session_id\":\"$sid1\",\"cwd\":\"/tmp/test\"}"
    fire_hook Notification "{\"session_id\":\"$sid1\",\"cwd\":\"/tmp/test\"}"

    # Backdate to 3 minutes ago
    sql "UPDATE sessions SET updated_at = unixepoch() - 180 WHERE session_id='$sid1';"

    # Trigger re-render by creating a second session
    fire_hook SessionStart "{\"session_id\":\"$sid2\",\"cwd\":\"/tmp/test\"}"
    fire_hook UserPromptSubmit "{\"session_id\":\"$sid2\",\"cwd\":\"/tmp/test\"}"

    local out
    out=$(read_cache)
    [[ "$out" == *"3m"* ]]
}

@test "integration: blocked timer shows hours" {
    local sid1="timer-hr-1"
    local sid2="timer-hr-2"

    fire_hook SessionStart "{\"session_id\":\"$sid1\",\"cwd\":\"/tmp/test\"}"
    fire_hook UserPromptSubmit "{\"session_id\":\"$sid1\",\"cwd\":\"/tmp/test\"}"
    fire_hook Notification "{\"session_id\":\"$sid1\",\"cwd\":\"/tmp/test\"}"

    # Backdate to 2 hours ago
    sql "UPDATE sessions SET updated_at = unixepoch() - 7200 WHERE session_id='$sid1';"

    # Trigger re-render
    fire_hook SessionStart "{\"session_id\":\"$sid2\",\"cwd\":\"/tmp/test\"}"
    fire_hook UserPromptSubmit "{\"session_id\":\"$sid2\",\"cwd\":\"/tmp/test\"}"

    local out
    out=$(read_cache)
    [[ "$out" == *"2h"* ]]
}

# ── 5. Multiple sessions ────────────────────────────────────────────

@test "integration: 3 sessions show correct counts" {
    for i in 1 2 3; do
        fire_hook SessionStart "{\"session_id\":\"multi-$i\",\"cwd\":\"/tmp/test\"}"
        fire_hook UserPromptSubmit "{\"session_id\":\"multi-$i\",\"cwd\":\"/tmp/test\"}"
    done

    # s1=working, s2=blocked, s3=idle
    fire_hook Notification "{\"session_id\":\"multi-2\",\"cwd\":\"/tmp/test\"}"
    fire_hook Stop "{\"session_id\":\"multi-3\",\"cwd\":\"/tmp/test\"}"

    [[ "$(count_status working)" -eq 1 ]]
    [[ "$(count_status blocked)" -eq 1 ]]
    [[ "$(count_status idle)" -eq 1 ]]

    local out
    out=$(read_cache)
    [[ "$out" == *"1."* ]]   # 1 idle
    [[ "$out" == *"1*"* ]]   # 1 working
    [[ "$out" == *"1!"* ]]   # 1 blocked
}

@test "integration: 6 sessions with mixed states" {
    for i in $(seq 1 6); do
        fire_hook SessionStart "{\"session_id\":\"big-$i\",\"cwd\":\"/tmp/test\"}"
        fire_hook UserPromptSubmit "{\"session_id\":\"big-$i\",\"cwd\":\"/tmp/test\"}"
    done

    # 2 working (1,2), 2 blocked (3,4), 2 idle (5,6)
    fire_hook Notification "{\"session_id\":\"big-3\",\"cwd\":\"/tmp/test\"}"
    fire_hook Notification "{\"session_id\":\"big-4\",\"cwd\":\"/tmp/test\"}"
    fire_hook Stop "{\"session_id\":\"big-5\",\"cwd\":\"/tmp/test\"}"
    fire_hook Stop "{\"session_id\":\"big-6\",\"cwd\":\"/tmp/test\"}"

    [[ "$(count_status working)" -eq 2 ]]
    [[ "$(count_status blocked)" -eq 2 ]]
    [[ "$(count_status idle)" -eq 2 ]]

    local out
    out=$(read_cache)
    [[ "$out" == *"2."* ]]
    [[ "$out" == *"2*"* ]]
    [[ "$out" == *"2!"* ]]
}

# ── 6. Concurrent hooks ─────────────────────────────────────────────

@test "integration: 10 parallel SessionStart+UserPromptSubmit creates" {
    local pids=()
    for i in $(seq 1 10); do
        (
            fire_hook SessionStart "{\"session_id\":\"conc-$i\",\"cwd\":\"/tmp/test\"}"
            fire_hook UserPromptSubmit "{\"session_id\":\"conc-$i\",\"cwd\":\"/tmp/test\"}"
        ) &
        pids+=($!)
    done
    # Tolerate cache-write races from concurrent mv
    for pid in "${pids[@]}"; do wait "$pid" || true; done

    [[ "$(count_sessions)" -eq 10 ]]
}

@test "integration: parallel mixed Notification/PostToolUse on different sessions" {
    # Setup: 10 working sessions
    for i in $(seq 1 10); do
        fire_hook SessionStart "{\"session_id\":\"mix-$i\",\"cwd\":\"/tmp/test\"}"
        fire_hook UserPromptSubmit "{\"session_id\":\"mix-$i\",\"cwd\":\"/tmp/test\"}"
    done

    # Even sessions get Notification, odd get PostToolUse — in parallel
    local pids=()
    for i in $(seq 1 10); do
        if (( i % 2 == 0 )); then
            fire_hook Notification "{\"session_id\":\"mix-$i\",\"cwd\":\"/tmp/test\"}" &
        else
            fire_hook PostToolUse "{\"session_id\":\"mix-$i\",\"cwd\":\"/tmp/test\"}" &
        fi
        pids+=($!)
    done
    for pid in "${pids[@]}"; do wait "$pid" || true; done

    [[ "$(count_status blocked)" -eq 5 ]]
    [[ "$(count_status working)" -eq 5 ]]
    [[ "$(count_sessions)" -eq 10 ]]
}

# ── 7. Rapid oscillation ────────────────────────────────────────────

@test "integration: sequential 4-flip on same session" {
    local sid="flip-seq"
    local json="{\"session_id\":\"$sid\",\"cwd\":\"/tmp/test\"}"

    fire_hook SessionStart "$json"
    fire_hook UserPromptSubmit "$json"

    # working → blocked → working → blocked → working
    fire_hook Notification "$json"
    [[ "$(get_status "$sid")" == "blocked" ]]
    fire_hook PostToolUse "$json"
    [[ "$(get_status "$sid")" == "working" ]]
    fire_hook Notification "$json"
    [[ "$(get_status "$sid")" == "blocked" ]]
    fire_hook PostToolUse "$json"
    [[ "$(get_status "$sid")" == "working" ]]
}

@test "integration: concurrent 10-flip leaves valid state" {
    local sid="flip-conc"
    local json="{\"session_id\":\"$sid\",\"cwd\":\"/tmp/test\"}"

    fire_hook SessionStart "$json"
    fire_hook UserPromptSubmit "$json"

    # Fire 10 alternating hooks concurrently
    local pids=()
    for i in $(seq 1 10); do
        if (( i % 2 == 0 )); then
            fire_hook PostToolUse "$json" &
        else
            fire_hook Notification "$json" &
        fi
        pids+=($!)
    done
    # Tolerate cache-write races from concurrent mv
    for pid in "${pids[@]}"; do wait "$pid" || true; done

    # Final state must be valid (either working or blocked — no corruption)
    local final
    final=$(get_status "$sid")
    [[ "$final" == "working" || "$final" == "blocked" ]]
    [[ "$(count_sessions)" -eq 1 ]]
}

# ── 8. Status-bar read ──────────────────────────────────────────────

@test "integration: status-bar output matches cache file" {
    local sid="sbar-1"
    fire_hook SessionStart "{\"session_id\":\"$sid\",\"cwd\":\"/tmp/test\"}"
    fire_hook UserPromptSubmit "{\"session_id\":\"$sid\",\"cwd\":\"/tmp/test\"}"

    local bar_out cache_out
    bar_out=$(run_status_bar)
    cache_out=$(read_cache)
    [[ "$bar_out" == "$cache_out" ]]
    [[ -n "$bar_out" ]]
}

@test "integration: status-bar empty when no cache" {
    rm -f "$CACHE"
    local out
    out=$(run_status_bar || true)
    [[ -z "$out" ]]
}

# ── 9. Session cleanup ──────────────────────────────────────────────

@test "integration: SessionEnd partial removal keeps other sessions" {
    fire_hook SessionStart "{\"session_id\":\"keep-1\",\"cwd\":\"/tmp/test\"}"
    fire_hook UserPromptSubmit "{\"session_id\":\"keep-1\",\"cwd\":\"/tmp/test\"}"
    fire_hook SessionStart "{\"session_id\":\"remove-1\",\"cwd\":\"/tmp/test\"}"
    fire_hook UserPromptSubmit "{\"session_id\":\"remove-1\",\"cwd\":\"/tmp/test\"}"

    [[ "$(count_sessions)" -eq 2 ]]

    fire_hook SessionEnd "{\"session_id\":\"remove-1\",\"cwd\":\"/tmp/test\"}"
    [[ "$(count_sessions)" -eq 1 ]]
    [[ "$(get_status keep-1)" == "working" ]]
    [[ -z "$(get_status remove-1)" ]]
}

@test "integration: last session removal zeros cache" {
    fire_hook SessionStart "{\"session_id\":\"last-1\",\"cwd\":\"/tmp/test\"}"
    fire_hook UserPromptSubmit "{\"session_id\":\"last-1\",\"cwd\":\"/tmp/test\"}"

    fire_hook SessionEnd "{\"session_id\":\"last-1\",\"cwd\":\"/tmp/test\"}"
    [[ "$(count_sessions)" -eq 0 ]]

    local out
    out=$(read_cache)
    [[ "$out" == *"0."* ]]
    [[ "$out" == *"0*"* ]]
    [[ "$out" == *"0!"* ]]
}

# ── 10. Subagent lifecycle ───────────────────────────────────────────

@test "integration: SubagentStart creates session with agent_type" {
    local parent="sub-parent"
    local sub="sub-child"

    fire_hook SessionStart "{\"session_id\":\"$parent\",\"cwd\":\"/tmp/test\"}"
    fire_hook UserPromptSubmit "{\"session_id\":\"$parent\",\"cwd\":\"/tmp/test\"}"

    fire_hook_with_pane SubagentStart "{\"session_id\":\"$parent\",\"subagent_id\":\"$sub\",\"subagent_type\":\"researcher\",\"cwd\":\"/tmp/test\"}"

    [[ "$(get_status "$sub")" == "working" ]]
    local atype
    atype=$(sql "SELECT agent_type FROM sessions WHERE session_id='$sub';")
    [[ "$atype" == "researcher" ]]
    [[ "$(count_sessions)" -eq 2 ]]
}

@test "integration: Stop atomically cleans subagents and idles count stable" {
    local parent="sub-stop-parent"
    local sub1="sub-stop-c1"
    local sub2="sub-stop-c2"
    local other="sub-stop-other"

    # Create parent + 2 subagents on same pane
    fire_hook_with_pane SessionStart "{\"session_id\":\"$parent\",\"cwd\":\"/tmp/test\"}"
    fire_hook_with_pane UserPromptSubmit "{\"session_id\":\"$parent\",\"cwd\":\"/tmp/test\"}"
    fire_hook_with_pane SubagentStart "{\"session_id\":\"$parent\",\"subagent_id\":\"$sub1\",\"subagent_type\":\"researcher\",\"cwd\":\"/tmp/test\"}"
    fire_hook_with_pane SubagentStart "{\"session_id\":\"$parent\",\"subagent_id\":\"$sub2\",\"subagent_type\":\"coder\",\"cwd\":\"/tmp/test\"}"

    # Create unrelated session (no pane)
    fire_hook SessionStart "{\"session_id\":\"$other\",\"cwd\":\"/tmp/test\"}"
    fire_hook UserPromptSubmit "{\"session_id\":\"$other\",\"cwd\":\"/tmp/test\"}"

    [[ "$(count_sessions)" -eq 4 ]]

    # Stop parent — should delete subagents on same pane, idle parent
    fire_hook_with_pane Stop "{\"session_id\":\"$parent\",\"cwd\":\"/tmp/test\"}"

    [[ "$(get_status "$parent")" == "idle" ]]
    [[ -z "$(get_status "$sub1")" ]]
    [[ -z "$(get_status "$sub2")" ]]
    [[ "$(get_status "$other")" == "working" ]]
    [[ "$(count_sessions)" -eq 2 ]]
}
