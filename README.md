# tmux-claude-agent-tracker

Track [Claude Code](https://docs.anthropic.com/en/docs/claude-code) agent sessions in your tmux status bar. Hook-driven, no daemon, no polling.

## Status Bar

```
0. 2* 1+ 1!3m
```

| Symbol | Meaning |
|--------|---------|
| `0.` | 0 idle |
| `2*` | 2 working |
| `1+` | 1 completed (output ready) |
| `1!3m` | 1 blocked for 3m (longest wait) |

Completed (`+`) auto-clears to idle when you focus the pane.

## Menu

`prefix + a` opens the agent list. Select to jump to pane.

```
Claude Agents
─────────────
! project-a/main
+ project-b/feature
* project-c/dev
. project-d/fix
─────────────
Quit      q
```

## How It Works

- Claude Code hooks fire on session events (start, stop, tool use, permission, failure)
- Each hook writes to a local SQLite database and pushes to a tmux option (~35ms)
- `refresh-client -S` triggers instant display via `#{@claude-tracker-status}`
- A periodic `#()` refresh keeps the blocked timer current
- Dead sessions are automatically reaped via tmux pane cross-referencing

No background daemon. No polling. Pure event-driven tracking.

See [ARCHITECTURE.md](ARCHITECTURE.md) for the full design.

## Install

### Requirements

- `tmux 3.0+`
- `sqlite3`
- `jq` (optional -- enables automatic Claude Code hook configuration)

### Quick Start

```bash
git clone https://github.com/KakkoiDev/tmux-claude-agent-tracker.git ~/.tmux/plugins/tmux-claude-agent-tracker
cd ~/.tmux/plugins/tmux-claude-agent-tracker && ./install.sh
```

The install script:
1. Symlinks the CLI to `~/.local/bin/`
2. Initializes the SQLite database
3. Adds the plugin to `~/.tmux.conf`
4. Configures Claude Code hooks in `~/.claude/settings.json` (requires `jq`)

If `jq` is not installed, the script prints the hook JSON for manual configuration.

### TPM

```bash
set -g @plugin 'KakkoiDev/tmux-claude-agent-tracker'
```

Then `prefix + I` to install. After TPM installs the plugin, run the hook installer:

```bash
~/.tmux/plugins/tmux-claude-agent-tracker/install.sh --hooks-only
```

### Claude Code Hooks

`./install.sh` automatically adds the required hooks to `~/.claude/settings.json`. To re-run just the hook configuration:

```bash
./install.sh --hooks-only
```

If you need to add them manually:

```json
{
  "hooks": {
    "SessionStart": [{ "matcher": "", "hooks": [{ "type": "command", "command": "tmux-claude-agent-tracker hook SessionStart" }] }],
    "SessionEnd": [{ "matcher": "", "hooks": [{ "type": "command", "command": "tmux-claude-agent-tracker hook SessionEnd" }] }],
    "UserPromptSubmit": [{ "matcher": "", "hooks": [{ "type": "command", "command": "tmux-claude-agent-tracker hook UserPromptSubmit" }] }],
    "PostToolUse": [{ "matcher": "", "hooks": [{ "type": "command", "command": "tmux-claude-agent-tracker hook PostToolUse" }] }],
    "PostToolUseFailure": [{ "matcher": "", "hooks": [{ "type": "command", "command": "tmux-claude-agent-tracker hook PostToolUseFailure" }] }],
    "Stop": [{ "matcher": "", "hooks": [{ "type": "command", "command": "tmux-claude-agent-tracker hook Stop" }] }],
    "Notification": [{ "matcher": "permission_prompt|elicitation_dialog", "hooks": [{ "type": "command", "command": "tmux-claude-agent-tracker hook Notification" }] }]
  }
}
```

### Hook Reference

| Hook | Fires when | Tracker action |
|------|-----------|----------------|
| `SessionStart` | Session begins or resumes | Create session row as idle |
| `UserPromptSubmit` | User sends a message | Set working |
| `PostToolUse` | Tool call succeeds | Set working (no-op if already) |
| `PostToolUseFailure` | Tool call fails or user rejects | Set working (clears stuck blocked state) |
| `Notification` | Permission prompt or elicitation dialog shown | Set blocked |
| `Stop` | Claude finishes responding | Set completed |
| `SessionEnd` | Session terminates | Delete session row |

**Why `PostToolUseFailure`?** Claude Code's `Stop` hook does not fire on user interrupt. If a user rejects a permission prompt and interrupts, the session stays stuck at `blocked` with no hook to clear it. `PostToolUseFailure` fires on tool rejection/failure and transitions `blocked` back to `working`, where `_reap_dead` can clean up.

**Why `permission_prompt|elicitation_dialog` matcher on Notification?** The `Notification` hook fires for multiple types: `permission_prompt`, `elicitation_dialog`, `idle_prompt`, `auth_success`. Both `permission_prompt` and `elicitation_dialog` mean Claude is waiting for user input. Without the filter, an `idle_prompt` notification would incorrectly show the session as blocked.

## Configuration

Set in `~/.tmux.conf`:

### Display

| Option | Default | Purpose |
|--------|---------|---------|
| `@claude-tracker-keybinding` | `a` | Menu key (after prefix) |
| `@claude-tracker-items-per-page` | `10` | Menu page size |
| `@claude-tracker-key-next` | `i` | Next page |
| `@claude-tracker-key-prev` | `o` | Previous page |
| `@claude-tracker-key-quit` | `q` | Quit menu |
| `@claude-tracker-show-project` | `0` | `1` to show project name |
| `@claude-tracker-status-interval` | `60` | Blocked timer refresh (seconds) |

### Colors

| Option | Default | Purpose |
|--------|---------|---------|
| `@claude-tracker-color-working` | `black` | Working count color |
| `@claude-tracker-color-blocked` | `black` | Blocked count color |
| `@claude-tracker-color-idle` | `black` | Idle count color |
| `@claude-tracker-color-completed` | `black` | Completed count color |

```bash
set -g @claude-tracker-color-working 'green'
set -g @claude-tracker-color-blocked 'red'
set -g @claude-tracker-color-idle 'yellow'
```

### Icons

Customize the status bar indicators:

| Option | Default | Purpose |
|--------|---------|---------|
| `@claude-tracker-icon-idle` | `.` | Idle indicator |
| `@claude-tracker-icon-working` | `*` | Working indicator |
| `@claude-tracker-icon-completed` | `+` | Completed indicator |
| `@claude-tracker-icon-blocked` | `!` | Blocked indicator |

```bash
set -g @claude-tracker-icon-idle '💤'
set -g @claude-tracker-icon-working '🔨'
set -g @claude-tracker-icon-completed '✅'
set -g @claude-tracker-icon-blocked '🔴'
```

### Sound

| Option | Default | Purpose |
|--------|---------|---------|
| `@claude-tracker-sound` | `0` | `1` to play system sound on block |

Sound is automatically disabled when `@claude-tracker-on-blocked` is set, since you handle notifications via the hook instead.

### State Transition Hooks

Run shell commands when an agent changes state. Each command receives 4 arguments: `$1=from_state $2=to_state $3=session_id $4=project_name`. Commands run asynchronously (backgrounded).

| Option | Default | Fires on |
|--------|---------|----------|
| `@claude-tracker-on-working` | `""` | Any state -> working |
| `@claude-tracker-on-completed` | `""` | Any state -> completed |
| `@claude-tracker-on-blocked` | `""` | Any state -> blocked |
| `@claude-tracker-on-idle` | `""` | Any state -> idle |
| `@claude-tracker-on-transition` | `""` | Any state change (catch-all) |

```bash
set -g @claude-tracker-on-blocked 'notify-send "Claude blocked" "Agent in $4 needs attention"'
set -g @claude-tracker-on-completed 'paplay /usr/share/sounds/complete.oga'
```

**Migrating from `@claude-tracker-sound`:** If you used `@claude-tracker-sound 1` for blocked notifications, switch to `@claude-tracker-on-blocked` for more control:

```bash
# Before
set -g @claude-tracker-sound '1'

# After
set -g @claude-tracker-on-blocked 'paplay /usr/share/sounds/freedesktop/stereo/complete.oga'
```

## Commands

| Command | Purpose |
|---------|---------|
| `tmux-claude-agent-tracker init` | Create DB |
| `tmux-claude-agent-tracker hook <event>` | Handle Claude hook (stdin JSON) |
| `tmux-claude-agent-tracker status-bar` | Output cached status string |
| `tmux-claude-agent-tracker refresh` | Re-render from DB, update tmux option (no output) |
| `tmux-claude-agent-tracker menu [page]` | Show agent menu |
| `tmux-claude-agent-tracker goto <target>` | Jump to pane |
| `tmux-claude-agent-tracker cleanup` | Remove stale sessions |

## Testing

```bash
bats tests/
```

## License

MIT
