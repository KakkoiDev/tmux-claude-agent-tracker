#!/usr/bin/env bash
# helpers.sh - Config loading and tmux helpers for tmux-claude-agent-tracker

# ── Plugin directory resolution ──────────────────────────────────────

if [[ -z "${CLAUDE_TRACKER_PLUGIN_DIR:-}" ]]; then
    CLAUDE_TRACKER_PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
SCRIPTS_DIR="$CLAUDE_TRACKER_PLUGIN_DIR/scripts"

# ── tmux option helpers ──────────────────────────────────────────────

get_tmux_option() {
    local option="$1" default="${2:-}"
    local value
    value=$(tmux show-option -gqv "$option" 2>/dev/null) || true
    printf '%s' "${value:-$default}"
}

# ── config loading ───────────────────────────────────────────────────

KEYBINDING=""
ITEMS_PER_PAGE=""
KEY_NEXT=""
KEY_PREV=""
KEY_QUIT=""
COLOR_WORKING=""
COLOR_BLOCKED=""
COLOR_IDLE=""
SOUND=""

load_config() {
    local cache="/tmp/claude-tracker-config"

    # Use cache if fresh (< 60s) — shared across all hook invocations
    if [[ -f "$cache" ]]; then
        local age now
        now=$(date +%s)
        age=$(( now - $(stat -f %m "$cache" 2>/dev/null || stat -c %Y "$cache" 2>/dev/null || echo 0) ))
        if [[ "$age" -lt 60 ]]; then
            source "$cache"
            return
        fi
    fi

    KEYBINDING=$(get_tmux_option "@claude-tracker-keybinding" "a")
    ITEMS_PER_PAGE=$(get_tmux_option "@claude-tracker-items-per-page" "10")
    KEY_NEXT=$(get_tmux_option "@claude-tracker-key-next" "i")
    KEY_PREV=$(get_tmux_option "@claude-tracker-key-prev" "o")
    KEY_QUIT=$(get_tmux_option "@claude-tracker-key-quit" "q")
    COLOR_WORKING=$(get_tmux_option "@claude-tracker-color-working" "black")
    COLOR_BLOCKED=$(get_tmux_option "@claude-tracker-color-blocked" "black")
    COLOR_IDLE=$(get_tmux_option "@claude-tracker-color-idle" "black")
    SOUND=$(get_tmux_option "@claude-tracker-sound" "0")

    # Atomic write — safe for concurrent hook invocations
    cat > "${cache}.tmp" <<EOF
KEYBINDING='$KEYBINDING'
ITEMS_PER_PAGE='$ITEMS_PER_PAGE'
KEY_NEXT='$KEY_NEXT'
KEY_PREV='$KEY_PREV'
KEY_QUIT='$KEY_QUIT'
COLOR_WORKING='$COLOR_WORKING'
COLOR_BLOCKED='$COLOR_BLOCKED'
COLOR_IDLE='$COLOR_IDLE'
SOUND='$SOUND'
EOF
    mv -f "${cache}.tmp" "$cache"
}

# ── version check ────────────────────────────────────────────────────

check_tmux_version() {
    local required="${1:-3.0}"
    local current
    current=$(tmux -V 2>/dev/null | sed 's/[^0-9.]//g') || return 1
    [[ -z "$current" ]] && return 1

    local cur_major cur_minor req_major req_minor
    cur_major="${current%%.*}"
    cur_minor="${current#*.}"; cur_minor="${cur_minor%%.*}"
    req_major="${required%%.*}"
    req_minor="${required#*.}"; req_minor="${req_minor%%.*}"

    if [[ "$cur_major" -gt "$req_major" ]]; then return 0; fi
    if [[ "$cur_major" -eq "$req_major" && "$cur_minor" -ge "$req_minor" ]]; then return 0; fi
    return 1
}

ensure_tmux_version() {
    if ! check_tmux_version "3.0"; then
        echo "tmux-claude-agent-tracker requires tmux 3.0+" >&2
        return 1
    fi
}
