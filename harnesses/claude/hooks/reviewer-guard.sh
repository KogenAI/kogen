#!/bin/bash
# reviewer-guard.sh — PreToolUse hook for reviewer-phoenix / reviewer-static
#
# HOOK-MANIFEST:
# event: PreToolUse
# matcher: Write|Edit|MultiEdit|Monitor
# surface: user_global
# signal: AGENT_TYPE
# role: reviewer-phoenix|reviewer-static
# harnesses: all
# registration only (hand-authored body) — the registry entry for this hook
# is `kind: registration`, which emits ONLY the settings.json wiring; the
# check logic below is NOT generated and is safe to hand-edit.
#
# Blocks all mutating tools when the active agent is "reviewer-phoenix" or
# "reviewer-static". Reviewers are read-only analysis roles: Read, Grep, Glob
# only, plus Bash (gated by reviewer-bash-allowlist.sh to codegen-log and safe
# read-only utilities) to write their session-log section via codegen-log.
# All other agents pass through unconditionally.

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
Write)
    deny "BLOCKED by reviewer-guard: tool Write forbidden for $AGENT_TYPE (read-only role)"
    exit 0
    ;;
Edit)
    # SCHEMA: session-log.md — canonical session log filename pattern
    # NOTE: raw Edit on session logs is ALSO denied globally by
    # session-log-writer-only.sh (codegen-log is the sole writer). This arm
    # still gates the path shape for any non-log Edit attempt.
    rel=$(repo_relative "$FILE_PATH") &&
        printf '%s' "$rel" | grep -qE "codegen/logging/${SESSION_LOG_NAME_RE}" && exit 0
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
