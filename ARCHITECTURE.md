# Architecture

## Process Boundaries

```mermaid
sequenceDiagram
    participant C as Claude Code<br/>(Node.js)
    participant H as Hook script<br/>(bash, ~65-77ms)
    participant T as Tmux server<br/>(C)

    C->>H: hook JSON on stdin
    H->>H: sqlite3 write → DB
    H->>H: render cache → file
    H->>T: tmux refresh-client -S

    T->>H: #(status-bar)
    H-->>T: cat cache file
    T->>H: prefix+a
    H-->>T: display-menu
```

No daemon. Each hook is a fire-and-forget bash process. SQLite is the only shared state.

## Push/Pull Split

**Push (hooks):** Claude event -> write DB -> render cache -> refresh tmux. Synchronous.

**Pull (status-bar):** Tmux calls `status-bar` every N seconds. Reads cache file. Sub-millisecond. Blocked timer is recomputed live from DB; all other data served from cache.

Cache write uses `mv -f` for atomicity.

## State Machine

```mermaid
stateDiagram-v2
    [*] --> working : SessionStart

    working --> idle : Stop
    working --> blocked : Notification (permission)

    idle --> working : UserPromptSubmit / PostToolUse
    blocked --> working : UserPromptSubmit / PostToolUse

    idle --> [*] : SessionEnd
    blocked --> [*] : SessionEnd
    working --> [*] : SessionEnd
```

Transition guards:
- `Stop` -> idle (unconditional)
- `UserPromptSubmit` -> working (unconditional, handles idle->working and blocked->working)
- `PostToolUse` -> working (`WHERE status!='working'`, no-op when already working)
- `Notification` -> blocked (`WHERE status != 'blocked'`, no-op if already blocked)

## Hook Performance

State-changing hooks run in ~77ms. No-op hooks (e.g. PostToolUse when already working) run in ~65ms.

### Hot path optimizations

PostToolUse and Notification are the most frequent state-changing hooks. They use a combined SQL pattern that does UPDATE + render query in a single sqlite3 call:

```sql
UPDATE sessions SET status='...', updated_at=unixepoch()
    WHERE session_id='...' AND status != '...';
SELECT CASE WHEN changes() = 0 THEN '' ELSE (render query) END;
```

If `changes() = 0`, the hook is a no-op — skip render, skip tmux refresh.

These hooks also skip `_ensure_session` (the session is guaranteed to exist by the time PostToolUse or Notification fires). This eliminates 2 sqlite3 calls from the hot path.

### Config loading

`load_config` (helpers.sh) fetches tmux options and caches them to `$TRACKER_DIR/config_cache`. The full check runs `date` + `stat` to verify freshness (~8ms in subprocesses).

Hook path uses `_load_config_fast` which sources the cache file directly without freshness check. Non-hook paths (status-bar, menu) use the full `load_config` with 60s TTL.

### Cost breakdown (state-changing hook)

| Cost | Source |
|------|--------|
| ~7ms | bash startup + source helpers.sh |
| ~9ms | sqlite3 (combined UPDATE + render) |
| ~5ms | source config cache |
| ~6ms | write cache file (printf + mv) |
| ~7ms | tmux refresh-client -S |

### Asymmetric transition latency

`blocked → working` (PostToolUse) feels faster than `working → blocked` (Notification) despite identical script execution times. The delay is upstream in Claude Code — there is a gap between when Claude decides it needs permission and when it fires the Notification hook. This is outside the tracker's control.

### What was eliminated

| Removed | Savings |
|---------|---------|
| `jq` (5 calls per hook) | ~15ms (subprocess spawns) |
| `cat` for stdin | ~3ms (replaced with `read -r`) |
| `_ensure_session` on hot path | ~7ms (1 fewer sqlite3) |
| Separate render sqlite3 call | ~8ms (batched into hook SQL) |
| `date`+`stat` in config check | ~8ms (source file directly) |
| render+refresh on no-ops | ~15ms (skip via `SELECT changes()`) |

## Self-Healing (_ensure_session)

Called for session-creating hooks (SessionStart, UserPromptSubmit, SubagentStart). Registers the session if missing, backfills tmux pane data if incomplete.

Hot-path hooks (PostToolUse, Notification, Stop, TeammateIdle) skip this — their UPDATEs are safe no-ops if the session doesn't exist yet.

Handles: missed SessionStart, lost tracking, missing tmux info.

- `SessionStart`: `INSERT OR REPLACE` (authoritative upsert)
- `_ensure_session`: `INSERT OR IGNORE` (gap-fill only)

## Session Cleanup

Sessions can leak (crashes, killed panes). Three cleanup mechanisms:

1. **SessionEnd hook** (normal exit)
2. **`_reap_dead`** (hook path, throttled to 30s): cross-references `tmux list-panes` with stored pane IDs, deletes dead ones
3. **`cmd_cleanup`** (manual): deletes sessions older than 24h + dead pane check

`_reap_dead` checks pane liveness via `tmux list-panes` and process inspection via `pgrep`. Working/blocked sessions on live panes without a claude child process are cleaned up (Ctrl+C case).

## SQLite as IPC

Multiple concurrent hook processes. WAL mode handles this:

- **WAL mode**: readers never block writers
- **busy_timeout=100ms**: concurrent writes wait instead of failing
- Each `sqlite3` invocation is a new connection

## Subagent Tracking

`_ensure_session` evicts stale main sessions per pane but preserves subagent entries (`agent_type IS NOT NULL`). One main session per pane, N subagents.

## Scan (Fallback Discovery)

`cmd_scan` finds Claude processes via `pgrep` in tmux panes. Conditional INSERT skips panes already tracked by hooks. Throttled to once per 30s.

## Hook Events

| Hook | Transition | Guard |
|------|-----------|-------|
| SessionStart | (new) -> working | INSERT OR REPLACE |
| UserPromptSubmit | any -> working | unconditional |
| PostToolUse | blocked/idle -> working | `status!='working'` |
| Stop | any -> idle | unconditional |
| Notification | working -> blocked | `status='working'` |
| SessionEnd | any -> (deleted) | unconditional |
| SubagentStart | (new) -> working | INSERT OR REPLACE |
| SubagentStop | any -> (deleted) | unconditional |
| TeammateIdle | any -> idle | unconditional |

## Database Schema

```sql
CREATE TABLE sessions (
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
```

## File Structure

```
tmux-claude-agent-tracker/
├── claude-tracker.tmux          # TPM entry point
├── scripts/
│   ├── helpers.sh               # Config loading, tmux helpers
│   └── tracker.sh               # Core: hook, menu, status-bar, goto
├── tests/
│   ├── tracker.bats             # BATS test suite
│   └── helpers.bash             # Test helpers, DB setup, mocks
├── install.sh                   # TPM + manual install
└── bin/
    └── tmux-claude-agent-tracker    # Wrapper -> scripts/tracker.sh
```
