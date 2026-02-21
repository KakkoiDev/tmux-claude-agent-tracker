#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN="$SCRIPT_DIR/bin/tmux-claude-agent-tracker"
LINK="$HOME/.local/bin/tmux-claude-agent-tracker"
CLAUDE_SETTINGS="$HOME/.claude/settings.json"

# ── dependency check ─────────────────────────────────────────────────

missing=()
for cmd in sqlite3 jq tmux; do
    command -v "$cmd" >/dev/null || missing+=("$cmd")
done
if [[ ${#missing[@]} -gt 0 ]]; then
    echo "Missing dependencies: ${missing[*]}" >&2
    echo "Install them and re-run." >&2
    exit 1
fi

# ── symlink CLI to PATH ─────────────────────────────────────────────

mkdir -p "$(dirname "$LINK")"
ln -sf "$BIN" "$LINK"
ln -sf "$SCRIPT_DIR/bin/claude-agent-tracker" "$HOME/.local/bin/claude-agent-tracker"
echo "CLI: $LINK"

# ── init DB ──────────────────────────────────────────────────────────

"$SCRIPT_DIR/scripts/tracker.sh" init

# ── add plugin to tmux.conf ──────────────────────────────────────────

TMUX_CONF="$HOME/.tmux.conf"
PLUGIN_LINE="run-shell '$SCRIPT_DIR/claude-tracker.tmux'"
if ! grep -qF "claude-tracker.tmux" "$TMUX_CONF" 2>/dev/null; then
    echo "" >> "$TMUX_CONF"
    echo "# Claude Agent Tracker" >> "$TMUX_CONF"
    echo "$PLUGIN_LINE" >> "$TMUX_CONF"
    echo "tmux.conf: added plugin line"
else
    echo "tmux.conf: already configured"
fi

# ── configure Claude Code hooks ──────────────────────────────────────

TRACKER_EVENTS=(
    SessionStart SessionEnd UserPromptSubmit
    PostToolUse PostToolUseFailure Stop Notification
    SubagentStart SubagentStop
)
# Notification must match only permission_prompt (other types are not permission waits)
TRACKER_MATCHERS=([Notification]="permission_prompt")

install_hooks() {
    if [[ ! -f "$CLAUDE_SETTINGS" ]]; then
        # Create minimal settings with hooks
        local hooks_json="{"
        local first=true
        for event in "${TRACKER_EVENTS[@]}"; do
            $first || hooks_json+=","
            first=false
            local matcher="${TRACKER_MATCHERS[$event]:-}"
            hooks_json+="\"$event\":[{\"matcher\":\"$matcher\",\"hooks\":[{\"type\":\"command\",\"command\":\"tmux-claude-agent-tracker hook $event\"}]}]"
        done
        hooks_json+="}"

        jq -n --argjson hooks "$hooks_json" '{
            "$schema": "https://json.schemastore.org/claude-code-settings.json",
            hooks: $hooks
        }' > "$CLAUDE_SETTINGS"
        echo "hooks: created $CLAUDE_SETTINGS with all tracker hooks"
        return
    fi

    # Settings file exists — merge tracker hooks into existing hooks
    local tmp="${CLAUDE_SETTINGS}.tmp"
    local changed=false

    cp "$CLAUDE_SETTINGS" "$tmp"

    # Ensure top-level "hooks" key exists
    if ! jq -e '.hooks' "$tmp" >/dev/null 2>&1; then
        jq '. + {hooks: {}}' "$tmp" > "${tmp}.2" && mv "${tmp}.2" "$tmp"
    fi

    for event in "${TRACKER_EVENTS[@]}"; do
        local cmd="tmux-claude-agent-tracker hook $event"

        # Check if this exact command already exists under this event
        if jq -e --arg event "$event" --arg cmd "$cmd" '
            .hooks[$event] // [] | map(.hooks[]? | select(.command == $cmd)) | length > 0
        ' "$tmp" >/dev/null 2>&1; then
            continue
        fi

        # Append tracker hook entry to this event
        local matcher="${TRACKER_MATCHERS[$event]:-}"
        jq --arg event "$event" --arg cmd "$cmd" --arg matcher "$matcher" '
            .hooks[$event] = (.hooks[$event] // []) + [{
                matcher: $matcher,
                hooks: [{type: "command", command: $cmd}]
            }]
        ' "$tmp" > "${tmp}.2" && mv "${tmp}.2" "$tmp"
        changed=true
    done

    if $changed; then
        mv "$tmp" "$CLAUDE_SETTINGS"
        echo "hooks: added tracker hooks to $CLAUDE_SETTINGS"
    else
        rm -f "$tmp"
        echo "hooks: already configured"
    fi
}

install_hooks

# ── done ─────────────────────────────────────────────────────────────

echo ""
echo "Done. Reload tmux: tmux source ~/.tmux.conf"
echo "Then restart Claude Code for hooks to take effect."
