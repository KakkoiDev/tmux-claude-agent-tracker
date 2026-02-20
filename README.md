# tmux-claude-agent-tracker

Track [Claude Code](https://docs.anthropic.com/en/docs/claude-code) agent sessions in your tmux status bar. Hook-driven, no daemon, no polling.

## Status Bar

```
0. 2* 1!3m
```

| Symbol | Meaning |
|--------|---------|
| `0.` | 0 idle |
| `2*` | 2 working |
| `1!3m` | 1 blocked for 3m (longest wait) |

## Menu

`prefix + a` opens the agent list. Select to jump to pane.

```
Claude Agents
─────────────
! project-a/main
* project-b/feature
. project-c/dev
─────────────
Quit      q
```

## How It Works

- Claude Code hooks fire on session events (start, stop, tool use, permission request)
- Each hook writes to a local SQLite database (~25ms)
- A pre-rendered cache file is updated and tmux refreshes
- Status bar reads the cache file (sub-millisecond)
- Dead sessions are automatically reaped via tmux pane cross-referencing

No background daemon. No polling. Pure event-driven tracking.

See [ARCHITECTURE.md](ARCHITECTURE.md) for the full design.

## Install

### TPM

```bash
set -g @plugin 'KakkoiDev/tmux-claude-agent-tracker'
```

Then `prefix + I`.

### Manual

```bash
git clone https://github.com/KakkoiDev/tmux-claude-agent-tracker.git ~/.tmux/plugins/tmux-claude-agent-tracker
cd ~/.tmux/plugins/tmux-claude-agent-tracker
./install.sh
```

### Claude Code Hooks

`./install.sh` automatically adds the required hooks to `~/.claude/settings.json`. If you need to add them manually, add a hook entry for each event:

```json
{
  "hooks": {
    "SessionStart": [{ "matcher": "", "hooks": [{ "type": "command", "command": "tmux-claude-agent-tracker hook SessionStart" }] }],
    "SessionEnd": [{ "matcher": "", "hooks": [{ "type": "command", "command": "tmux-claude-agent-tracker hook SessionEnd" }] }],
    "UserPromptSubmit": [{ "matcher": "", "hooks": [{ "type": "command", "command": "tmux-claude-agent-tracker hook UserPromptSubmit" }] }],
    "PostToolUse": [{ "matcher": "", "hooks": [{ "type": "command", "command": "tmux-claude-agent-tracker hook PostToolUse" }] }],
    "Stop": [{ "matcher": "", "hooks": [{ "type": "command", "command": "tmux-claude-agent-tracker hook Stop" }] }],
    "Notification": [{ "matcher": "", "hooks": [{ "type": "command", "command": "tmux-claude-agent-tracker hook Notification" }] }],
    "SubagentStart": [{ "matcher": "", "hooks": [{ "type": "command", "command": "tmux-claude-agent-tracker hook SubagentStart" }] }],
    "SubagentStop": [{ "matcher": "", "hooks": [{ "type": "command", "command": "tmux-claude-agent-tracker hook SubagentStop" }] }]
  }
}
```

### Requirements

- `tmux 3.0+`
- `sqlite3`
- `jq`

## Configuration

Set in `~/.tmux.conf`:

| Option | Default | Purpose |
|--------|---------|---------|
| `@claude-tracker-keybinding` | `a` | Menu key |
| `@claude-tracker-items-per-page` | `10` | Menu page size |
| `@claude-tracker-key-next` | `i` | Next page |
| `@claude-tracker-key-prev` | `o` | Previous page |
| `@claude-tracker-key-quit` | `q` | Quit menu |
| `@claude-tracker-color-working` | `black` | Working count color |
| `@claude-tracker-color-blocked` | `black` | Blocked count color |
| `@claude-tracker-color-idle` | `black` | Idle count color |
| `@claude-tracker-sound` | `0` | `1` to play sound on block |
| `@claude-tracker-status-interval` | `2` | Status refresh (seconds) |

```bash
set -g @claude-tracker-color-working 'green'
set -g @claude-tracker-color-blocked 'red'
set -g @claude-tracker-color-idle 'yellow'
```

## Commands

| Command | Purpose |
|---------|---------|
| `tmux-claude-agent-tracker init` | Create DB |
| `tmux-claude-agent-tracker hook <event>` | Handle Claude hook (stdin JSON) |
| `tmux-claude-agent-tracker status-bar` | Output status string |
| `tmux-claude-agent-tracker menu [page]` | Show agent menu |
| `tmux-claude-agent-tracker goto <target>` | Jump to pane |
| `tmux-claude-agent-tracker cleanup` | Remove stale sessions |

## Testing

```bash
bats tests/
```

## License

MIT
