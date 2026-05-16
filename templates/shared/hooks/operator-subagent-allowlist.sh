#!/bin/bash
# operator-subagent-allowlist.sh — PreToolUse Agent hook.
#
# HOOK-MANIFEST:
# event: PreToolUse
# matcher: Agent
# surface: user_global
# signal: CLAUDE_ROLE
# role: *
#
# Enforces subagent spawn rules across all launcher modes:
#
#   Built-in subagents {Plan, general-purpose, statusline-setup} denied always.
#   Empty subagent_type denied defensively (fail-closed).
#   Explore denied unless CLAUDE_ROLE ∈ {debug, design}.
#   Project subagents (planner-*, developer-*, reviewer-*, committer, etc.) allowed everywhere.
#
# Registered on matcher "Agent" in claude-code-settings.json PreToolUse.

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
parse_input

# Only guard the Agent tool (subagent spawn).
if [ "$TOOL_NAME" != "Agent" ]; then
    exit 0
fi

subagent_type=$(printf '%s' "$RAW_INPUT" | jq -r '.tool_input.subagent_type // ""' 2>/dev/null)

debug_log operator-subagent-allowlist "role=${CLAUDE_ROLE:-} subagent_type=$subagent_type"

# Built-in subagent types — denied in all launcher modes.
if [ "$subagent_type" = "Plan" ] || [ "$subagent_type" = "general-purpose" ] || [ "$subagent_type" = "statusline-setup" ]; then
    deny "BLOCKED by operator-subagent-allowlist: built-in subagent $subagent_type is denied in all launcher modes."
    exit 0
fi

# Empty subagent_type — deny defensively (fail-closed).
if [ -z "$subagent_type" ]; then
    deny "BLOCKED by operator-subagent-allowlist: subagent_type is empty — cannot determine safe subagent. Specify a named project subagent."
    exit 0
fi

# Explore — allowed only under debug/design operator roles.
if [ "$subagent_type" = "Explore" ]; then
    if [ "${CLAUDE_ROLE:-}" = "debug" ] || [ "${CLAUDE_ROLE:-}" = "design" ]; then
        exit 0
    fi
    deny "BLOCKED by operator-subagent-allowlist: Explore subagent is only available under claude-debug or claude-design launcher modes. Use planner-phoenix / planner-html / etc. instead for investigation within a standard orchestrator session."
    exit 0
fi

# All other subagent types (project subagents) — allow.
exit 0
