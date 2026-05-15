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

# Inspector write guard — only active for inspector agents.
# If not an inspector, allow (this hook is not responsible for non-inspector constraints).
case "${AGENT_TYPE:-}" in
inspector | inspector-phoenix | codex-inspector | cursor-inspector) ;;
*) exit 0 ;;
esac

case "$TOOL_NAME" in
Write | Edit | MultiEdit | NotebookEdit)
    deny "BLOCKED by inspector-write-guard: tool $TOOL_NAME is forbidden for Inspector (read-only role)"
    exit 0
    ;;
esac

exit 0
