#!/bin/bash

# Server Cleanup Script
# Kills servers running on ports used by a specific workspace

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

cleanup_workspace_servers() {
    local workspace_path="$1"
    local quiet_mode="${2:-false}"

    if [ ! -f "$workspace_path/.env" ]; then
        return 0
    fi

    local killed_something=false

    # Use tail -1 to get last occurrence (workspace overrides template defaults)
    local port=$(grep "^PORT=" "$workspace_path/.env" 2>/dev/null | tail -1 | cut -d'=' -f2)

    if [ -n "$port" ] && lsof -ti tcp:$port >/dev/null 2>&1; then
        if [ "$quiet_mode" != "true" ]; then
            echo "🔄 Killing Phoenix server on port $port..."
        fi
        lsof -ti tcp:$port | xargs kill -9 2>/dev/null || true
        killed_something=true
    fi

    if [ "$killed_something" = "true" ]; then
        sleep 1
    fi

    return 0
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    if [ -z "$1" ]; then
        echo "Usage: $0 <workspace_path> [--quiet]"
        echo "Example: $0 /path/to/workspace --quiet"
        exit 1
    fi

    workspace_path="$1"
    quiet_mode="false"
    [ "$2" = "--quiet" ] || [ "$2" = "-q" ] && quiet_mode="true"

    if [ "$quiet_mode" != "true" ]; then
        echo "🧹 Cleaning up servers for workspace: $(basename "$workspace_path")"
    fi

    cleanup_workspace_servers "$workspace_path" "$quiet_mode"

    if [ "$quiet_mode" != "true" ]; then
        echo "✅ Server cleanup complete"
    fi
fi
