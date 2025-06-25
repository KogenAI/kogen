#!/bin/bash

# Simple CI wrapper script for Optimum Codegen
# Looks for 'make ci' and runs it, saving status for workspace-info.sh

set -e

CI_STATUS_FILE="codegen/.ci_status"

# Function to update CI status - always rewrites the entire file
update_status() {
    local status="$1"
    local output="$2"
    >"$CI_STATUS_FILE" # Clear the file first
    echo "$(date '+%Y-%m-%d %H:%M:%S')" >>"$CI_STATUS_FILE"
    echo "$status" >>"$CI_STATUS_FILE"
    if [ -n "$output" ]; then
        echo "" >>"$CI_STATUS_FILE"
        # Extract only coverage information from the output
        echo "$output" | grep "\[TOTAL\]" >>"$CI_STATUS_FILE" 2>/dev/null || true
    fi
}

echo "🔍 Running CI checks..."

# Set initial status
update_status "🔄 Overall Status: IN_PROGRESS"

# Check if there's a Makefile with ci target
if [ -f "Makefile" ] && grep -q "^ci:" "Makefile"; then
    # Run CI and show output while capturing it
    set +e
    ci_output=$(make ci 2>&1 | tee /dev/tty)
    ci_exit_code=$?
    set -e

    if [ $ci_exit_code -eq 0 ]; then
        update_status "🎉 Overall Status: PASSED" "$ci_output"
        echo "✅ CI checks passed!"
    else
        update_status "💥 Overall Status: FAILED" "$ci_output"
        echo "❌ CI checks failed"
        exit 1
    fi
else
    update_status "🎉 Overall Status: SKIPPED"
    echo "⚠️  No 'make ci' target found in this project"
    echo "💡 Add a 'make ci' target to your Makefile for CI enforcement"
fi
