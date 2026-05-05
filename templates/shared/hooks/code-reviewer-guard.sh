#!/bin/bash
# code-reviewer-guard.sh — PreToolUse hook for code-reviewer
#
# Blocks all mutating tools when the active agent is "code-reviewer".
# The code-reviewer is a read-only analysis role: Read, Grep, Glob only.
# All other agents pass through unconditionally.

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
parse_input

debug_log cr-guard "tool=$TOOL_NAME agent=$AGENT_TYPE"

# Only gate code-reviewer; allow all other agents unconditionally
if [ "$AGENT_TYPE" != "code-reviewer" ]; then
    exit 0
fi

case "$TOOL_NAME" in
Bash)
    deny "BLOCKED by cr-guard: tool Bash forbidden for code-reviewer (read-only role)"
    exit 0
    ;;
Write)
    deny "BLOCKED by cr-guard: tool Write forbidden for code-reviewer (read-only role)"
    exit 0
    ;;
Edit)
    if printf '%s' "$FILE_PATH" | grep -qE 'codegen/logging/[^/]+_(session|step[0-9]+_[^/]+)\.md$'; then
        exit 0
    fi
    deny "BLOCKED by cr-guard: code-reviewer may not edit files outside session logs: $FILE_PATH"
    exit 0
    ;;
MultiEdit)
    deny "BLOCKED by cr-guard: tool MultiEdit forbidden for code-reviewer (read-only role)"
    exit 0
    ;;
Monitor)
    deny "BLOCKED by cr-guard: tool Monitor forbidden for code-reviewer (read-only role)"
    exit 0
    ;;
esac

exit 0
