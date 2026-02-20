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

# Set a fast status-interval so #() cache refreshes quickly after hook updates.
# The status-bar command just cats a pre-rendered file, so low intervals are cheap.
desired_interval=$(tmux show-option -gqv "@claude-tracker-status-interval" 2>/dev/null)
desired_interval="${desired_interval:-2}"
current_interval=$(tmux show-option -gqv status-interval 2>/dev/null)
current_interval="${current_interval:-15}"
if [[ "$current_interval" -gt "$desired_interval" ]]; then
    tmux set -g status-interval "$desired_interval"
fi

# Inject status bar (strip stale entries first, then add if missing)
current_status_right=$(tmux show-option -gqv status-right)
# Remove legacy "#(claude-agent-tracker status-bar) | " left by old installs or session restore
current_status_right="${current_status_right//#(claude-agent-tracker status-bar) | /}"
status_cmd="#($SCRIPTS_DIR/tracker.sh status-bar)"
if [[ "$current_status_right" != *"tracker.sh status-bar"* ]]; then
    tmux set -g status-right "${status_cmd} | ${current_status_right}"
else
    tmux set -g status-right "${current_status_right}"
fi
