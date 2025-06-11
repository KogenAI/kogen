#!/bin/bash

# Shared utilities for Optimum Codegen scripts
# Source this file to get access to common variables and functions

if [ "$OCG_CLI" = "true" ]; then
    export OCG_CMD="ocg"
else
    export OCG_CMD="make"
fi

# Function to open a workspace in Cursor consistently
open_cursor_workspace() {
    local workspace_path="$1"
    local feature_name="$2"
    local success_message="$3"

    if command -v cursor >/dev/null 2>&1; then
        if [ -f "$workspace_path/${feature_name}.code-workspace" ]; then
            cursor "$workspace_path/${feature_name}.code-workspace" &
        else
            cursor "$workspace_path" &
        fi

        echo "$success_message"
    else
        echo "❌ Cursor command not found. Please install Cursor or open the workspace manually:"
        echo "   📁 $workspace_path"
        return 1
    fi
}
