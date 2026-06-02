#!/bin/bash
# reviewer-guard.sh — PreToolUse hook for reviewer-phoenix / reviewer-static
#
# HOOK-MANIFEST:
# event: PreToolUse
# matcher: Bash|Write|Edit|MultiEdit|Monitor
# surface: user_global
# signal: AGENT_TYPE
# role: reviewer-phoenix|reviewer-static
# harnesses: all
#
# Blocks all mutating tools when the active agent is "reviewer-phoenix" or
# "reviewer-static". Reviewers are read-only analysis roles: Read, Grep, Glob
# only, plus Edit on session logs. All other agents pass through unconditionally.

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
parse_input

debug_log reviewer-guard "tool=$TOOL_NAME agent=$AGENT_TYPE"

# Only gate reviewer agents; allow all other agents unconditionally
case "$AGENT_TYPE" in
reviewer-phoenix | reviewer-static) ;;
*)
    exit 0
    ;;
esac

case "$TOOL_NAME" in
Bash)
    deny "BLOCKED by reviewer-guard: tool Bash forbidden for $AGENT_TYPE (read-only role)"
    exit 0
    ;;
Write)
    deny "BLOCKED by reviewer-guard: tool Write forbidden for $AGENT_TYPE (read-only role)"
    exit 0
    ;;
Edit)
    # SCHEMA: session-log.md — canonical session log filename pattern
    rel=$(repo_relative "$FILE_PATH") &&
        printf '%s' "$rel" | grep -qE 'codegen/logging/[0-9]{8}_[0-9]{6}(_[a-z0-9-]+)?_(session|step[0-9]+_[a-z0-9-]+)\.md$' && exit 0
    deny "BLOCKED by reviewer-guard: $AGENT_TYPE may not edit files outside session logs: $FILE_PATH"
    exit 0
    ;;
MultiEdit)
    deny "BLOCKED by reviewer-guard: tool MultiEdit forbidden for $AGENT_TYPE (read-only role)"
    exit 0
    ;;
Monitor)
    deny "BLOCKED by reviewer-guard: tool Monitor forbidden for $AGENT_TYPE (read-only role)"
    exit 0
    ;;
esac

exit 0
