#!/bin/bash

# Simple CI wrapper script for Optimum Codegen
# Looks for 'make ci' and runs it, saving status for workspace-info.sh
# Supports monorepo structure (backend/ + mobile/)

set -e

CI_STATUS_FILE="codegen/.ci_status"

# Detect if we're in a monorepo
IS_MONOREPO=false
if [ -d "backend" ] && [ -d "mobile" ]; then
    IS_MONOREPO=true
fi

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

# Run CI checks based on project structure
if [ "$IS_MONOREPO" = true ]; then
    # Monorepo: Run both backend and mobile CI
    if [ $INTERACTIVE -eq 1 ]; then
        echo "🔍 Running CI checks for monorepo (backend + mobile)..."
    fi

    backend_failed=false
    mobile_failed=false
    combined_output=""

    # Run backend CI
    if [ -f "backend/Makefile" ] && grep -q "^ci:" "backend/Makefile"; then
        if [ $INTERACTIVE -eq 1 ]; then
            echo ""
            echo "📦 Backend CI..."
        fi
        set +e
        backend_output=$(cd backend && make ci 2>&1)
        backend_exit_code=$?
        set -e

        if [ $INTERACTIVE -eq 1 ]; then
            echo "$backend_output"
        fi

        combined_output+="=== Backend CI ===\n$backend_output\n\n"

        if [ $backend_exit_code -ne 0 ]; then
            backend_failed=true
        fi
    else
        if [ $INTERACTIVE -eq 1 ]; then
            echo "⚠️  No backend/Makefile with ci target"
        fi
    fi

    # Run mobile CI
    if [ -d "mobile" ] && command -v flutter &>/dev/null; then
        if [ $INTERACTIVE -eq 1 ]; then
            echo ""
            echo "📱 Mobile CI..."
        fi
        set +e
        mobile_output=$(cd mobile && flutter analyze 2>&1 && flutter test 2>&1 && dart format --output=none --set-exit-if-changed lib/ test/ 2>&1)
        mobile_exit_code=$?
        set -e

        if [ $INTERACTIVE -eq 1 ]; then
            echo "$mobile_output"
        fi

        combined_output+="=== Mobile CI ===\n$mobile_output"

        if [ $mobile_exit_code -ne 0 ]; then
            mobile_failed=true
        fi
    else
        if [ $INTERACTIVE -eq 1 ]; then
            echo "⚠️  Flutter not installed or mobile/ directory missing"
        fi
    fi

    # Determine overall status
    if [ "$backend_failed" = true ] || [ "$mobile_failed" = true ]; then
        update_status "💥 Overall Status: FAILED" "$combined_output"
        if [ $INTERACTIVE -eq 1 ]; then
            echo ""
            echo "❌ CI checks failed"
            [ "$backend_failed" = true ] && echo "   - Backend: FAILED"
            [ "$mobile_failed" = true ] && echo "   - Mobile: FAILED"
        fi
        exit 1
    else
        update_status "🎉 Overall Status: PASSED" "$combined_output"
        if [ $INTERACTIVE -eq 1 ]; then
            echo ""
            echo "✅ All CI checks passed!"
            echo "   - Backend: PASSED"
            echo "   - Mobile: PASSED"
        fi
    fi
else
    # Regular project: Run make ci if available
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
fi
