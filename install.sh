#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN="$SCRIPT_DIR/bin/tmux-claude-agent-tracker"
LINK="$HOME/.local/bin/tmux-claude-agent-tracker"

# Check dependencies
for cmd in sqlite3 jq tmux; do
    command -v "$cmd" >/dev/null || { echo "Missing: $cmd" >&2; exit 1; }
done

# Symlink bin wrapper to PATH
mkdir -p "$(dirname "$LINK")"
ln -sf "$BIN" "$LINK"
ln -sf "$SCRIPT_DIR/bin/claude-agent-tracker" "$HOME/.local/bin/claude-agent-tracker"

# Init DB
"$SCRIPT_DIR/scripts/tracker.sh" init

# Add plugin to tmux.conf if not already there
TMUX_CONF="$HOME/.tmux.conf"
PLUGIN_LINE="run-shell '$SCRIPT_DIR/claude-tracker.tmux'"
if ! grep -qF "claude-tracker.tmux" "$TMUX_CONF" 2>/dev/null; then
    echo "" >> "$TMUX_CONF"
    echo "# Claude Agent Tracker" >> "$TMUX_CONF"
    echo "$PLUGIN_LINE" >> "$TMUX_CONF"
    echo "Added to $TMUX_CONF"
else
    echo "Already in $TMUX_CONF"
fi

# Set up status-right if not configured
if ! tmux show-option -gqv status-right 2>/dev/null | grep -q "tracker.sh status-bar"; then
    current=$(tmux show-option -gqv status-right 2>/dev/null || echo "%H:%M %d-%b-%y")
    tmux set -g status-right "#($SCRIPT_DIR/scripts/tracker.sh status-bar) | $current" 2>/dev/null || true
fi

echo "Installed. Reload tmux: tmux source ~/.tmux.conf"
