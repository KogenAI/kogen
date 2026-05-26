#!/bin/bash
# claude-inspector-write-guard.sh — PreToolUse hook for Inspector (belt-and-suspenders)
#
# HOOK-MANIFEST:
# event: PreToolUse
# matcher: Write|Edit|MultiEdit|NotebookEdit
# surface: per_call_inspector
# signal: AGENT_TYPE
# role: inspector|inspector-phoenix
# harnesses: claude_code
# rationale: Claude Code per-call inspector hook; Pi uses load-gate tool restriction
#
# Blocks all write/edit tools when invoked for any Inspector call.
# Write, Edit, MultiEdit, and NotebookEdit are already denied via --disallowed-tools
# in RunnerImpl. This hook is a belt-and-suspenders layer in case --disallowed-tools
# is bypassed or reordered.

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
parse_input

require_inspector_agent_type

case "$TOOL_NAME" in
Write | Edit | MultiEdit | NotebookEdit)
    deny "BLOCKED by claude-inspector-write-guard: tool $TOOL_NAME is forbidden for Inspector (read-only role)"
    exit 0
    ;;
esac

exit 0
