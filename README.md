# tmux-claude-agent-tracker

Track Claude Code sessions in your tmux status bar. Hook-driven, no daemon, no polling.

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

## Install

### TPM

```bash
set -g @plugin 'your-user/tmux-claude-agent-tracker'
```

Then `prefix + I`.

### Manual

```bash
./install.sh
```

Requires: `sqlite3`, `jq`, `tmux 3.0+`.

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

## Technical Details

See [ARCHITECTURE.md](ARCHITECTURE.md).
