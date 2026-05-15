#!/bin/bash
# operator-subagent-allowlist.sh — PreToolUse Agent hook.
#
# Under CLAUDE_ROLE=debug or design, the only legitimate subagent spawn is
# Explore (read-only parallel investigation per the operator's design-doc
# authoring intent). Every other subagent type has either a write surface
# (developer-*, committer) or is mismatched to the operator role's purpose
# (planner-*, reviewer-*, build, inspector-*). Deny those at the spawn site
# instead of relying on downstream per-tool-call hooks to contain them.

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
parse_input

# Active only for the two operator roles that allow Agent in their --tools list.
if [ "${CLAUDE_ROLE:-}" != "debug" ] && [ "${CLAUDE_ROLE:-}" != "design" ]; then
    exit 0
fi

# Only guard the Agent tool (subagent spawn).
if [ "$TOOL_NAME" != "Agent" ]; then
    exit 0
fi

subagent_type=$(printf '%s' "$RAW_INPUT" | jq -r '.tool_input.subagent_type // ""' 2>/dev/null)

debug_log operator-subagent-allowlist "role=$CLAUDE_ROLE subagent_type=$subagent_type"

if [ "$subagent_type" = "Explore" ]; then
    exit 0
fi

deny "BLOCKED by operator-subagent-allowlist: ${CLAUDE_ROLE} mode may only spawn Explore subagents (read-only parallel investigation). Got subagent_type=\"$subagent_type\". For implementation work, exit the operator session and use the standard orchestrator flow."
exit 0
