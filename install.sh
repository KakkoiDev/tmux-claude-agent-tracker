#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN="$SCRIPT_DIR/bin/claude-agent-tracker"
LINK="$HOME/.local/bin/claude-agent-tracker"

# Check dependencies
for cmd in sqlite3 jq tmux; do
    command -v "$cmd" >/dev/null || { echo "Missing: $cmd" >&2; exit 1; }
done

# Symlink to PATH
mkdir -p "$(dirname "$LINK")"
ln -sf "$BIN" "$LINK"

# Initialize database
"$BIN" init

echo "Installed: $LINK"
