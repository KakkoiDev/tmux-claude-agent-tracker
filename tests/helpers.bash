#!/usr/bin/env bash
# Test helpers — fresh DB + mocked externals for each test

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS_DIR="$PROJECT_ROOT/scripts"

# Per-test temp directory
setup_test_env() {
    TEST_TMPDIR=$(mktemp -d)
    export TRACKER_DIR="$TEST_TMPDIR"
    export DB="$TRACKER_DIR/tracker.db"
    export CACHE="$TRACKER_DIR/status_cache"

    # Color defaults (normally loaded from tmux options)
    export COLOR_WORKING="black"
    export COLOR_BLOCKED="black"
    export COLOR_IDLE="black"
    export COLOR_COMPLETED="black"
    export TMUX_PANE=""

    # Icon defaults
    export ICON_IDLE="."
    export ICON_WORKING="*"
    export ICON_COMPLETED="+"
    export ICON_BLOCKED="!"

    # Hook defaults (none configured)
    export HOOK_ON_WORKING=""
    export HOOK_ON_COMPLETED=""
    export HOOK_ON_BLOCKED=""
    export HOOK_ON_IDLE=""
    export HOOK_ON_TRANSITION=""
    export _HAS_HOOKS="0"

    # Initialize DB schema (suppress PRAGMA output)
    mkdir -p "$TRACKER_DIR"
    sqlite3 "$DB" <<'SQL' >/dev/null 2>&1
PRAGMA journal_mode=WAL;
PRAGMA busy_timeout=100;
CREATE TABLE IF NOT EXISTS sessions (
    session_id    TEXT PRIMARY KEY,
    status        TEXT NOT NULL DEFAULT 'working'
        CHECK(status IN ('working', 'blocked', 'idle', 'completed')),
    cwd           TEXT NOT NULL,
    project_name  TEXT NOT NULL,
    git_branch    TEXT,
    prompt_summary TEXT,
    agent_type    TEXT,
    tmux_pane     TEXT,
    tmux_target   TEXT,
    started_at    INTEGER NOT NULL DEFAULT (unixepoch()),
    updated_at    INTEGER NOT NULL DEFAULT (unixepoch())
);
SQL
}

teardown_test_env() {
    [[ -d "${TEST_TMPDIR:-}" ]] && rm -rf "$TEST_TMPDIR"
}

# Direct SQL helper
sql() { printf '.timeout 100\n%s\n' "$*" | sqlite3 "$DB"; }

# Insert a session row directly
insert_session() {
    local sid="$1" status="${2:-working}" pane="${3:-}"
    local updated="${4:-}"
    sql "INSERT INTO sessions (session_id, status, cwd, project_name, tmux_pane)
         VALUES ('$sid', '$status', '/tmp/test', 'test', '$pane');"
    if [[ -n "$updated" ]]; then
        sql "UPDATE sessions SET updated_at=$updated WHERE session_id='$sid';"
    fi
}

# Source tracker functions without executing main
source_tracker_functions() {
    # Override externals before sourcing
    load_config() { true; }
    get_tmux_option() { echo "${2:-}"; }
    tmux() { true; }
    git() { true; }
    # Platform helper needed by throttle logic
    _file_mtime() {
        case "$(uname)" in
            Darwin) stat -f %m "$1" ;;
            *)      stat -c %Y "$1" ;;
        esac
    }

    # Use awk to strip shebang, set -euo, source line, load_config, and case block
    # Then sed to override path variables with test paths
    eval "$(awk '
        /^#!\/usr\/bin\/env bash/ { next }
        /^set -euo pipefail/ { next }
        /^source / { next }
        /^load_config/ { next }
        /^case "\$\{1:-\}"/, /^esac$/ { next }
        { print }
    ' "$SCRIPTS_DIR/tracker.sh" | \
    sed "s|^TRACKER_DIR=.*|TRACKER_DIR=\"$TRACKER_DIR\"|" | \
    sed "s|^DB=.*|DB=\"$DB\"|" | \
    sed "s|^CACHE=.*|CACHE=\"$CACHE\"|" | \
    sed "s|^SCRIPTS_DIR=.*|SCRIPTS_DIR=\"$SCRIPTS_DIR\"|")"
}

# Count sessions by status
count_status() {
    sql "SELECT COUNT(*) FROM sessions WHERE status='$1';"
}

# Get session status
get_status() {
    sql "SELECT status FROM sessions WHERE session_id='$1';"
}

# Total session count
count_sessions() {
    sql "SELECT COUNT(*) FROM sessions;"
}
