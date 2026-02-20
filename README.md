# tmux-claude-agent-tracker

Hook-based Claude Code session tracker for tmux. Event-driven, zero polling, no daemon.

## Install

### TPM (recommended)

Add to `~/.tmux.conf`:

```bash
set -g @plugin 'your-user/tmux-claude-agent-tracker'
```

Then `prefix + I` to install.

### Manual

```bash
./install.sh
```

This will:
- Symlink `bin/tmux-claude-agent-tracker` to `~/.local/bin`
- Initialize the database
- Add `run-shell` line to `~/.tmux.conf`

Requires: `sqlite3`, `jq`, `tmux 3.0+`.

## File Structure

```
tmux-claude-agent-tracker/
├── claude-tracker.tmux          # TPM entry point
├── scripts/
│   ├── helpers.sh               # Config loading, tmux helpers
│   └── tracker.sh               # Core logic: hook, menu, status-bar, goto
├── install.sh                   # TPM + manual install
└── bin/
    └── tmux-claude-agent-tracker     # Thin wrapper -> scripts/tracker.sh
```

## Usage

| Command | Purpose |
|---------|---------|
| `tmux-claude-agent-tracker init` | Create DB and directory |
| `tmux-claude-agent-tracker hook <event>` | Handle Claude Code hook (stdin JSON) |
| `tmux-claude-agent-tracker status-bar` | Output tmux status string from cache |
| `tmux-claude-agent-tracker menu [page]` | Show paginated tmux display-menu |
| `tmux-claude-agent-tracker goto <target>` | Navigate to tmux pane |
| `tmux-claude-agent-tracker cleanup` | Remove stale sessions |

## Status Bar Format

`0. 2* 1!3m` -- all three counts always visible, blocked shows duration

- `.` = idle
- `*` = working
- `!` = blocked (with duration suffix)

## Menu

`prefix + a` opens the agent menu. With pagination:

```
Claude Agents (1/3)
─────────────────────
! project-a/main
* project-b/feature
. project-c/dev
─────────────────────
Next      i
Quit      q
```

- Select an agent to jump to its tmux pane
- `i` / `o` navigate pages (when >10 agents)
- `q` closes the menu

## Configuration

Tmux options (set in `~/.tmux.conf`):

| Option | Default | Purpose |
|--------|---------|---------|
| `@claude-tracker-keybinding` | `a` | Menu trigger key |
| `@claude-tracker-items-per-page` | `10` | Menu page size |
| `@claude-tracker-key-next` | `i` | Next page key |
| `@claude-tracker-key-prev` | `o` | Previous page key |
| `@claude-tracker-key-quit` | `q` | Quit menu key |
| `@claude-tracker-color-working` | `black` | tmux color for working count |
| `@claude-tracker-color-blocked` | `black` | tmux color for blocked count |
| `@claude-tracker-color-idle` | `black` | tmux color for idle count |
| `@claude-tracker-sound` | `0` | `1` to play sound on blocked |

Example:

```bash
set -g @claude-tracker-keybinding 'a'
set -g @claude-tracker-items-per-page '15'
set -g @claude-tracker-color-working 'green'
set -g @claude-tracker-color-blocked 'red'
```

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

The cache file (`~/.tmux-claude-agent-tracker/status_cache`) is the bridge. Hooks write it. Status-bar reads it. The hot path (tmux polling) never touches SQLite. The expensive path (hook processing) only runs when state actually changes.

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

Transition guards prevent stuck states:
- `Stop` sets idle unconditionally
- `UserPromptSubmit` sets working unconditionally (handles idle->working AND blocked->working)
- `PostToolUse` sets working if not already working (`WHERE status!='working'`). Fires on every tool use but is a no-op when already working (~5ms). Unblocks from both `blocked` and `idle`.
- `Notification` only blocks if currently working (`WHERE status='working'`). Prevents late/duplicate notifications from re-blocking a session after permission was already granted.

### Self-Healing Registration (_ensure_session)

Called **once at the top of every non-delete hook dispatch**, before the event-specific handler. This is the universal safety net -- any hook contact from any Claude session registers it if missing and backfills incomplete data.

Handles these edge cases without special-casing:
- **Missed SessionStart**: session opened before hooks were configured, or hook failed silently. Next tool use, prompt, stop, or notification registers it.
- **Lost tracking**: `SessionEnd` fired spuriously (reconnection, crash recovery). Next hook re-creates the session.
- **Missing tmux info**: session was created without pane data (non-tmux env, or pane info unavailable at creation time). Every subsequent hook backfills `tmux_pane` and `tmux_target` if they're empty and `$TMUX_PANE` is set.

Two INSERT strategies:
- `SessionStart` uses `INSERT OR REPLACE` -- full upsert, authoritative
- `_ensure_session` uses `INSERT OR IGNORE` -- never overwrites authoritative data, only fills gaps

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

Menu items call `run-shell 'tmux-claude-agent-tracker goto target'` instead of inline tmux commands. Display-menu command strings are parsed by tmux's command parser (not bash), making `\;` command chaining unreliable. The `goto` subcommand runs `switch-client`, `select-window`, `select-pane` as normal sequential bash calls.

### Complete Data Flow

```
settings.json                     ~/.tmux-claude-agent-tracker/
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

| Hook | Matcher | State Transition | Guard |
|------|---------|-----------------|-------|
| SessionStart | -- | (new) -> working | INSERT OR REPLACE |
| UserPromptSubmit | -- | any -> working | unconditional |
| PostToolUse | -- | blocked/idle -> working | `status!='working'` |
| Stop | -- | any -> idle | unconditional |
| Notification | `permission_prompt` | working -> blocked | `status='working'` |
| SessionEnd | -- | any -> (deleted) | unconditional |
| SubagentStart | -- | (new) -> working | INSERT OR REPLACE |
| SubagentStop | -- | any -> (deleted) | unconditional |
| TeammateIdle | -- | any -> idle | unconditional |

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
