# Architecture

## Process Boundaries

```
Claude Code (Node.js)       Hook script (bash, ~25ms)       Tmux server (C)
      |                           |                               |
      |--- hook JSON on stdin --->|                               |
      |                           |--- sqlite3 write ---> DB      |
      |                           |--- render cache --->  file    |
      |                           |--- tmux refresh ------------->|
      |                           |                               |
      |                           |<-- #(status-bar) --- cat file |
      |                           |<-- prefix+a ---- display-menu |
```

No daemon. Each hook is a fire-and-forget bash process (~25ms). SQLite is the only shared state.

## Push/Pull Split

**Push (hooks):** Claude event -> write DB -> render cache -> refresh tmux. Synchronous.

**Pull (status-bar):** Tmux calls `status-bar` every N seconds. Reads cache file. Sub-millisecond. Blocked timer is recomputed live from DB; all other data served from cache.

Cache write uses `mv -f` for atomicity.

## State Machine

```
                SessionStart
                     |
                     v
          +-----> working <-----+
          |          |          |
  UserPromptSubmit  Notification  PostToolUse
  PostToolUse      (permission)   UserPromptSubmit
          |          |          |
          v          v          |
        idle      blocked ------+
          |          |
      SessionEnd  SessionEnd
          |          |
          v          v
       (deleted)  (deleted)
```

Transition guards:
- `Stop` -> idle (unconditional)
- `UserPromptSubmit` -> working (unconditional, handles idle->working and blocked->working)
- `PostToolUse` -> working (`WHERE status!='working'`, no-op when already working)
- `Notification` -> blocked (`WHERE status='working'`, prevents re-blocking after permission granted)

## Self-Healing (_ensure_session)

Called at the top of every non-delete hook. Registers the session if missing, backfills tmux pane data if incomplete.

Handles: missed SessionStart, lost tracking, missing tmux info.

- `SessionStart`: `INSERT OR REPLACE` (authoritative upsert)
- `_ensure_session`: `INSERT OR IGNORE` (gap-fill only)

## Session Cleanup

Sessions can leak (crashes, killed panes). Three cleanup mechanisms:

1. **SessionEnd hook** (normal exit)
2. **`_reap_dead`** (status-bar path): cross-references `tmux list-panes` with stored pane IDs, deletes dead ones
3. **`cmd_cleanup`** (manual): deletes sessions older than 24h + dead pane check

`_reap_dead` only checks pane liveness. No process inspection (pgrep is unreliable on macOS with nodenv/nvm reparenting).

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
