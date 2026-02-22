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
5. Copies the Claude Code skill file to `~/.claude/skills/`

If `jq` is not installed, the script prints the hook JSON for manual configuration.

### TPM

```bash
set -g @plugin 'KakkoiDev/tmux-claude-agent-tracker'
```

Then `prefix + I` to install. TPM runs `claude-tracker.tmux` which automatically provisions CLI symlinks and the skill file. You only need to run the hook installer once:

```bash
~/.tmux/plugins/tmux-claude-agent-tracker/install.sh --hooks-only
```

## Uninstall

```bash
cd ~/.tmux/plugins/tmux-claude-agent-tracker && ./uninstall.sh
```

Removes all artifacts: CLI symlinks, tmux.conf lines, Claude Code hooks, skill file, data directory, and live tmux state.

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
# Desktop notification when blocked
set -g @claude-tracker-on-blocked 'notify-send "Claude blocked" "Agent in $4 needs attention"'

# Sound alert when completed or blocked
set -g @claude-tracker-on-completed 'paplay /usr/share/sounds/freedesktop/stereo/complete.oga'
set -g @claude-tracker-on-blocked 'paplay /usr/share/sounds/freedesktop/stereo/complete.oga'

# macOS equivalents
set -g @claude-tracker-on-completed 'afplay /System/Library/Sounds/Glass.aiff'
set -g @claude-tracker-on-blocked 'afplay /System/Library/Sounds/Glass.aiff'

# Phone push notifications via ntfy.sh (free, no account needed)
# 1. Install ntfy app on phone (App Store / Google Play)
# 2. Pick a unique topic name:
#      echo "claude-$(openssl rand -hex 4)"
# 3. Subscribe to that topic in the ntfy app
# 4. Add hooks (replace MY_TOPIC with your topic name):
set -g @claude-tracker-on-blocked 'curl -s -d "Agent in $4 needs attention" ntfy.sh/MY_TOPIC'
set -g @claude-tracker-on-completed 'curl -s -d "Agent in $4 finished" ntfy.sh/MY_TOPIC'
```

## Remote Access (Phone / Tablet)

Access your tmux sessions from a phone or tablet using [Tailscale](https://tailscale.com) + SSH. Tailscale creates an encrypted WireGuard tunnel — no port forwarding, no dynamic DNS.

### Linux

```bash
# Install Tailscale
curl -fsSL https://tailscale.com/install.sh | sh

# Enable Tailscale SSH (authenticates via Tailscale identity, no SSH keys needed)
sudo tailscale up --ssh

# Install SSH server if not already present
sudo apt install openssh-server   # Debian/Ubuntu
sudo dnf install openssh-server   # Fedora
```

### macOS

```bash
# Install Tailscale via Mac App Store or Homebrew
brew install --cask tailscale

# Open Tailscale from Applications — sign in and enable SSH in the menu bar icon
# Or from CLI:
sudo tailscale up --ssh

# macOS has SSH built in — enable it:
# System Settings > General > Sharing > Remote Login
```

### Phone Setup

1. Install Tailscale on your phone (App Store / Google Play) and sign in with the same account
2. Install an SSH client — **Termius** (iOS/Android, free) or **Termux** (Android)
3. Get your machine's Tailscale IP: `tailscale ip`
4. SSH from phone: `ssh user@100.x.y.z`
5. Attach to your session: `tmux attach`

### Verify

```bash
tailscale status    # device online
tailscale ip        # 100.x.y.z address
ssh localhost       # SSH works locally
```

## License

MIT
