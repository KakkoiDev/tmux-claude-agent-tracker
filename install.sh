#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN="$SCRIPT_DIR/bin/tmux-claude-agent-tracker"
LINK="$HOME/.local/bin/tmux-claude-agent-tracker"
CLAUDE_SETTINGS="$HOME/.claude/settings.json"
CODEX_CONFIG="$HOME/.codex/config.toml"
HOOKS_ONLY=false

for arg in "$@"; do
    case "$arg" in
        --hooks-only) HOOKS_ONLY=true ;;
    esac
done

# ── dependency check ─────────────────────────────────────────────────

missing=()
for cmd in sqlite3 tmux; do
    command -v "$cmd" >/dev/null || missing+=("$cmd")
done
if [[ ${#missing[@]} -gt 0 ]]; then
    echo "Missing dependencies: ${missing[*]}" >&2
    echo "Install them and re-run." >&2
    exit 1
fi

HAS_JQ=false
command -v jq >/dev/null && HAS_JQ=true

# ── hooks-only mode: skip CLI/DB/tmux.conf ───────────────────────────

if ! $HOOKS_ONLY; then

# ── symlink CLI to PATH ─────────────────────────────────────────────

mkdir -p "$(dirname "$LINK")"
ln -sf "$BIN" "$LINK"
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

# ── install skill file ────────────────────────────────────────────────

for skill_dir in "$SCRIPT_DIR"/.claude/skills/tmux-claude-agent-tracker*; do
    [[ -d "$skill_dir" ]] || continue
    skill_name="$(basename "$skill_dir")"
    skill_dest="$HOME/.claude/skills/$skill_name/SKILL.md"
    if [[ -f "$skill_dir/SKILL.md" ]]; then
        mkdir -p "$(dirname "$skill_dest")"
        cp -f "$skill_dir/SKILL.md" "$skill_dest"
        echo "Skill: $skill_dest"
    fi
done

fi  # end !HOOKS_ONLY

# ── configure Claude Code hooks ──────────────────────────────────────

TRACKER_EVENTS=(
    SessionStart SessionEnd UserPromptSubmit
    PostToolUse PostToolUseFailure Stop Notification PermissionRequest
    TaskCompleted
)
# Notification must match only permission_prompt or elicitation_dialog (user attention needed)
_get_matcher() {
    case "$1" in
        Notification) echo "permission_prompt|elicitation_dialog" ;;
        *) echo "" ;;
    esac
}

_print_manual_hooks() {
    cat <<'MANUAL_HOOKS'

Add the following to ~/.claude/settings.json under "hooks":

{
  "hooks": {
    "SessionStart": [{ "matcher": "", "hooks": [{ "type": "command", "command": "tmux-claude-agent-tracker hook SessionStart" }] }],
    "SessionEnd": [{ "matcher": "", "hooks": [{ "type": "command", "command": "tmux-claude-agent-tracker hook SessionEnd" }] }],
    "UserPromptSubmit": [{ "matcher": "", "hooks": [{ "type": "command", "command": "tmux-claude-agent-tracker hook UserPromptSubmit" }] }],
    "PostToolUse": [{ "matcher": "", "hooks": [{ "type": "command", "command": "tmux-claude-agent-tracker hook PostToolUse" }] }],
    "PostToolUseFailure": [{ "matcher": "", "hooks": [{ "type": "command", "command": "tmux-claude-agent-tracker hook PostToolUseFailure" }] }],
    "Stop": [{ "matcher": "", "hooks": [{ "type": "command", "command": "tmux-claude-agent-tracker hook Stop" }] }],
    "Notification": [{ "matcher": "permission_prompt|elicitation_dialog", "hooks": [{ "type": "command", "command": "tmux-claude-agent-tracker hook Notification" }] }],
    "PermissionRequest": [{ "matcher": "", "hooks": [{ "type": "command", "command": "tmux-claude-agent-tracker hook PermissionRequest" }] }],
    "TaskCompleted": [{ "matcher": "", "hooks": [{ "type": "command", "command": "tmux-claude-agent-tracker hook TaskCompleted" }] }]
  }
}
MANUAL_HOOKS
}

install_hooks() {
    if ! $HAS_JQ; then
        echo "hooks: jq not found — skipping auto-configuration"
        _print_manual_hooks
        return
    fi

    if [[ ! -f "$CLAUDE_SETTINGS" ]]; then
        # Create minimal settings with hooks
        local hooks_json="{"
        local first=true
        for event in "${TRACKER_EVENTS[@]}"; do
            $first || hooks_json+=","
            first=false
            local matcher
            matcher=$(_get_matcher "$event")
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
        local matcher
            matcher=$(_get_matcher "$event")
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

# ── configure Codex notify hook ──────────────────────────────────────

_print_manual_codex_notify() {
    cat <<'MANUAL_CODEX'

Add this to ~/.codex/config.toml:

notify = ["tmux-claude-agent-tracker", "codex-notify"]

MANUAL_CODEX
}

install_codex_notify() {
    local notify_line='notify = ["tmux-claude-agent-tracker", "codex-notify"]'
    mkdir -p "$(dirname "$CODEX_CONFIG")"

    if [[ ! -f "$CODEX_CONFIG" ]]; then
        {
            echo "# tmux-claude-agent-tracker"
            echo "$notify_line"
        } > "$CODEX_CONFIG"
        echo "codex: created $CODEX_CONFIG with notify hook"
        return
    fi

    if grep -Eq '^[[:space:]]*notify[[:space:]]*=' "$CODEX_CONFIG"; then
        if grep -Fq '"tmux-claude-agent-tracker", "codex-notify"' "$CODEX_CONFIG"; then
            echo "codex: notify hook already configured"
            return
        fi
        echo "codex: existing notify command found in $CODEX_CONFIG; leaving it unchanged"
        _print_manual_codex_notify
        return
    fi

    {
        echo ""
        echo "# tmux-claude-agent-tracker"
        echo "$notify_line"
    } >> "$CODEX_CONFIG"
    echo "codex: added notify hook to $CODEX_CONFIG"
}

install_codex_notify

# ── done ─────────────────────────────────────────────────────────────

echo ""
if $HOOKS_ONLY; then
    echo "Done. Restart Claude Code and Codex for hooks to take effect."
else
    echo "Done. Reload tmux: tmux source ~/.tmux.conf"
    echo "Then restart Claude Code and Codex for hooks to take effect."
fi
