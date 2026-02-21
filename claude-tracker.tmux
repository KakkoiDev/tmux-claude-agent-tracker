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

# Clear completed status when user navigates to a pane
tmux set-hook -g session-window-changed "run-shell -b '$SCRIPTS_DIR/tracker.sh pane-focus #{pane_id}'"
tmux set-hook -g window-pane-changed "run-shell -b '$SCRIPTS_DIR/tracker.sh pane-focus #{pane_id}'"
tmux set-hook -g client-session-changed "run-shell -b '$SCRIPTS_DIR/tracker.sh pane-focus #{pane_id}'"

# Set status-interval for periodic blocked timer refresh.
# Only lower it — never override a user's custom short interval.
tracker_interval=$(get_tmux_option "@claude-tracker-status-interval" "60")
current_interval=$(tmux show-option -gqv status-interval 2>/dev/null)
current_interval="${current_interval:-15}"
if [[ "$current_interval" -gt "$tracker_interval" ]]; then
    tmux set -g status-interval "$tracker_interval"
fi

# Initialize tmux option for instant status display
tmux set -gq @claude-tracker-status ""

# Inject status bar:
#   #{@claude-tracker-status}  — instant display, re-evaluated on refresh-client -S
#   #(tracker.sh refresh)      — periodic blocked timer update (no visible output)
current_status_right=$(tmux show-option -gqv status-right)

# Strip all tracker injections (legacy, old #() format, new #{@}+#() format)
current_status_right="${current_status_right//#(claude-agent-tracker status-bar) | /}"
if [[ "$current_status_right" == *"tracker.sh"* ]] || [[ "$current_status_right" == *"@claude-tracker-status"* ]]; then
    current_status_right=$(printf '%s' "$current_status_right" | sed -E \
        -e 's~#\{@claude-tracker-status\}~~g' \
        -e 's~#\([^)]*tracker\.sh (status-bar|refresh)\) [|] ~~g' \
        -e 's~#\([^)]*tracker\.sh (status-bar|refresh)\)~~g')
fi

status_cmd="#{@claude-tracker-status}#($SCRIPTS_DIR/tracker.sh refresh)"
tmux set -g status-right "${status_cmd} | ${current_status_right}"
