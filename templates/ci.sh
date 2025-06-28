#!/bin/bash

# Simple CI wrapper script for Optimum Codegen
# Looks for 'make ci' and runs it, saving status for workspace-info.sh

set -e

CI_STATUS_FILE="codegen/.ci_status"

# Check if we're running in background mode (set by startup.sh)
if [ -n "$CI_BACKGROUND" ]; then
    INTERACTIVE=0
else
    INTERACTIVE=1
fi

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

# Only show messages if running interactively
if [ $INTERACTIVE -eq 1 ]; then
    echo "🔍 Running CI checks..."
fi

# Set initial status
update_status "🔄 Overall Status: IN_PROGRESS"

# Check if there's a Makefile with ci target
if [ -f "Makefile" ] && grep -q "^ci:" "Makefile"; then
    # Run CI and capture output
    set +e
    if [ $INTERACTIVE -eq 1 ]; then
        # Interactive mode: show output while capturing
        ci_output=$(make ci 2>&1)
        ci_exit_code=$?
        # Show the output
        echo "$ci_output"
    else
        # Background mode: capture output silently
        ci_output=$(make ci 2>&1)
        ci_exit_code=$?
    fi
    set -e

    if [ $ci_exit_code -eq 0 ]; then
        update_status "🎉 Overall Status: PASSED" "$ci_output"
        if [ $INTERACTIVE -eq 1 ]; then
            echo "✅ CI checks passed!"
        fi
    else
        update_status "💥 Overall Status: FAILED" "$ci_output"
        if [ $INTERACTIVE -eq 1 ]; then
            echo "❌ CI checks failed"
        fi
        exit 1
    fi
else
    update_status "🎉 Overall Status: SKIPPED"
    if [ $INTERACTIVE -eq 1 ]; then
        echo "⚠️  No 'make ci' target found in this project"
        echo "💡 Add a 'make ci' target to your Makefile for CI enforcement"
    fi
fi
