# claude-agent-tracker

Hook-based Claude Code session tracker for tmux. Event-driven, zero polling, no daemon.

## Install

```bash
./install.sh
```

Requires: `sqlite3`, `jq`, `tmux`. Symlinks to `~/.local/bin`.

## Usage

| Command | Purpose |
|---------|---------|
| `claude-agent-tracker init` | Create DB and directory |
| `claude-agent-tracker hook <event>` | Handle Claude Code hook (stdin JSON) |
| `claude-agent-tracker status-bar` | Output tmux status string from cache |
| `claude-agent-tracker menu` | Show tmux display-menu with session list |
| `claude-agent-tracker goto <target>` | Navigate to tmux pane |
| `claude-agent-tracker cleanup` | Remove stale sessions |

## Status Bar Format

`2* 1!3m 1.` -- count per status, blocked shows duration

- `*` = working
- `!` = blocked (with duration suffix)
- `.` = idle

## Configuration

Environment variables:

| Variable | Default | Purpose |
|----------|---------|---------|
| `CLAUDE_TRACKER_COLOR_WORKING` | `black` | tmux color for working count |
| `CLAUDE_TRACKER_COLOR_BLOCKED` | `black` | tmux color for blocked count |
| `CLAUDE_TRACKER_COLOR_IDLE` | `black` | tmux color for idle count |
| `CLAUDE_TRACKER_SOUND` | `0` | `1` to play sound on blocked transition |

## Architecture

### The Three Boundaries

The system spans three process boundaries that never share memory:

```
Claude Code process          Your script            Tmux server
(Node.js)                    (bash, ~25ms)          (C, persistent)
      |                           |                       |
      |--- hook JSON on stdin --->|                       |
      |                           |--- sqlite3 write ---->| (DB on disk)
      |                           |--- tmux refresh ----->|
      |                           |                       |
      |                           |<-- tmux status-bar ---| (every 15s)
      |                           |<-- tmux display-menu -| (on prefix+a)
```

Each hook invocation is a separate bash process. No daemon. No long-running state. The script starts, does its work in ~25ms, and dies. SQLite is the only shared state.

### The Push/Pull Split

Two fundamentally different read patterns:

**Push path (hooks):** Claude fires an event -> script writes DB + renders cache + tells tmux to refresh. Latency matters (~25ms). Synchronous -- Claude blocks until hook completes.

**Pull path (status-bar):** Tmux calls `status-bar` every `status-interval` seconds. Just `cat`s a flat file. Sub-millisecond. No DB access.

The cache file (`~/.claude-agent-tracker/status_cache`) is the bridge. Hooks write it. Status-bar reads it. The hot path (tmux polling) never touches SQLite. The expensive path (hook processing) only runs when state actually changes.

The `mv -f` on the cache write makes it atomic -- tmux never reads a half-written file.

### State Machine

Three states, enforced by CHECK constraint:

```
                    SessionStart
                         |
                         v
              +-----> working <-----+
              |          |          |
  UserPromptSubmit   Notification   PostToolUse
  PostToolUse        (permission)   UserPromptSubmit
              |          |          |
              v          v          |
            idle      blocked ------+
              |          |
          SessionEnd  SessionEnd
              |          |
              v          v
           (deleted)  (deleted)
```

Transitions are permissive in code:
- `Stop` sets idle unconditionally
- `UserPromptSubmit` sets working unconditionally (handles idle->working AND blocked->working)
- `PostToolUse` is conditional: `WHERE status='blocked'` -- performance optimization since it fires on every tool use. No-op 99% of the time (~5ms).

### Lazy Registration (_ensure_session)

Sessions running before hooks were configured never fired `SessionStart`. The `_ensure_session` pattern: every UPDATE-based hook does a SELECT + conditional INSERT OR IGNORE before updating. If the session exists (common case), one extra SELECT (~2ms). If missing (first contact), creates the row from environment context (`$PWD`, `$TMUX_PANE`, git branch).

Two INSERT strategies:
- `SessionStart` uses `INSERT OR REPLACE` -- full upsert, authoritative
- `_ensure_session` uses `INSERT OR IGNORE` -- never overwrites authoritative data

### SQLite as IPC

Multiple Claude sessions fire hooks concurrently. Each hook is a separate bash process. WAL mode makes this work:

- **WAL mode** (set at init, persistent): Readers never block writers, writers never block readers
- **busy_timeout=100ms**: Concurrent writes wait instead of failing
- `.timeout 100` per connection: Each `sqlite3` invocation is a new connection

### Environment Inheritance

`$TMUX_PANE` is set by tmux, inherited by Claude Code, inherited by hook subprocesses. The hook resolves pane ID to navigable target:

```
$TMUX_PANE=%24 -> tmux display-message -t %24 -p '#{session_name}:#{window_index}.#{pane_index}'
                -> dotfiles-master:1.1
```

Stored once at session creation, reused for menu navigation.

### The goto Indirection

Menu items call `run-shell 'claude-agent-tracker goto target'` instead of inline tmux commands. Display-menu command strings are parsed by tmux's command parser (not bash), making `\;` command chaining unreliable. The `goto` subcommand runs `switch-client`, `select-window`, `select-pane` as normal sequential bash calls.

### Complete Data Flow

```
settings.json                     ~/.claude-agent-tracker/
(hook config)                     +-- tracker.db  (WAL mode)
     |                            +-- status_cache (flat file)
     | registers 10 hooks              |          |
     v                                 |          |
Claude Code --stdin JSON--> hook --sqlite3--> DB  |
                              |                   |
                              +--printf/mv--> cache
                              |
                              +--tmux refresh-client -S--> tmux server
                                                              |
                                  agent_status.conf           |
                                  +-- status-right: #(status-bar) --cat cache--> status line
                                  +-- bind-key a: menu --sqlite3 query--> display-menu
                                                    |
                                                    +-- run-shell goto --> switch/select pane
```

### Why No Daemon

Zero persistent processes. Every invocation is fire-and-forget.

- No crash recovery needed -- nothing to crash
- No PID management -- no pidfiles, no orphaned processes
- No memory leaks -- each invocation is a fresh process
- Instant deployment -- change the script, next hook picks it up
- Concurrency is free -- SQLite WAL handles multiple writers

Tradeoff: ~25ms process startup per hook (bash + jq + sqlite3). Negligible for a system that fires at most once per tool use.

### Cleanup Safety Net

Sessions can leak (Claude crashes, network drops, pane killed). `cleanup` handles this:

1. **Time-based**: Delete anything older than 24h
2. **Liveness check**: Cross-reference `tmux list-panes -a` with stored pane IDs, delete dead ones

## Hook Events

| Hook | Matcher | State Transition |
|------|---------|-----------------|
| SessionStart | -- | (new) -> working |
| UserPromptSubmit | -- | idle/blocked -> working |
| PostToolUse | -- | blocked -> working (conditional) |
| Stop | -- | working -> idle |
| Notification | `permission_prompt` | working -> blocked |
| SessionEnd | -- | any -> (deleted) |
| SubagentStart | -- | (new) -> working |
| SubagentStop | -- | any -> (deleted) |
| TeammateIdle | -- | any -> idle |

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
