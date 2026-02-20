#!/usr/bin/env bash
# TPM entry point for tmux-claude-agent-tracker

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export CLAUDE_TRACKER_PLUGIN_DIR="$CURRENT_DIR"
SCRIPTS_DIR="$CURRENT_DIR/scripts"

source "$SCRIPTS_DIR/helpers.sh"

ensure_tmux_version || exit 1
load_config

# Init DB if needed
"$SCRIPTS_DIR/tracker.sh" init 2>/dev/null

# Bind menu key
tmux bind-key "$KEYBINDING" run-shell "$SCRIPTS_DIR/tracker.sh menu"

# Inject status bar (only if not already present)
current_status_right=$(tmux show-option -gqv status-right)
status_cmd="#($SCRIPTS_DIR/tracker.sh status-bar)"
if [[ "$current_status_right" != *"tracker.sh status-bar"* ]]; then
    tmux set -g status-right "${status_cmd} | ${current_status_right}"
fi
