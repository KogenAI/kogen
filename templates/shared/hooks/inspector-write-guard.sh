#!/bin/bash
# inspector-write-guard.sh — PreToolUse hook for Inspector (belt-and-suspenders)
#
# Blocks all write/edit tools when invoked for any Inspector call.
# Write, Edit, MultiEdit, and NotebookEdit are already denied via --disallowed-tools
# in RunnerImpl. This hook is a belt-and-suspenders layer in case --disallowed-tools
# is bypassed or reordered.
#
# Exit codes:
#   0 — allow the tool call
#   2 — block the tool call (Claude Code PreToolUse convention)

set -euo pipefail

input=$(cat)

tool_name=$(printf '%s' "$input" | jq -r '.tool_name // ""')

case "$tool_name" in
Write | Edit | MultiEdit | NotebookEdit)
    printf 'BLOCKED by inspector-write-guard: tool %s is forbidden for Inspector (read-only role)\n' "$tool_name" >&2
    exit 2
    ;;
esac

exit 0
