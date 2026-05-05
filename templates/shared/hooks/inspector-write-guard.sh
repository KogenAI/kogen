#!/bin/bash
# inspector-write-guard.sh — PreToolUse hook for Inspector (belt-and-suspenders)
#
# Blocks all write/edit tools when invoked for any Inspector call.
# Write, Edit, MultiEdit, and NotebookEdit are already denied via --disallowed-tools
# in RunnerImpl. This hook is a belt-and-suspenders layer in case --disallowed-tools
# is bypassed or reordered.

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
parse_input

case "$TOOL_NAME" in
Write | Edit | MultiEdit | NotebookEdit)
    deny "BLOCKED by inspector-write-guard: tool $TOOL_NAME is forbidden for Inspector (read-only role)"
    exit 0
    ;;
esac

exit 0
