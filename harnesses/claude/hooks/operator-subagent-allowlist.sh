#!/bin/bash
# operator-subagent-allowlist.sh — PreToolUse Agent hook.
#
# HOOK-MANIFEST:
# event: PreToolUse
# matcher: Agent
# surface: user_global
# signal: CLAUDE_ROLE_FAMILY
# role: *
# harnesses: all
# GENERATED FROM shared/enforcement/registry.yaml — DO NOT EDIT
#
# Enforces subagent spawn rules across all launcher modes:
#
#   Built-in subagents {Plan, general-purpose, statusline-setup} denied always.
#   Empty subagent_type denied defensively (fail-closed).
#   Explore denied unless active role ∈ {debug, shape, ops}.
#   Project subagents (planner-*, developer-*, reviewer-*, committer, etc.) allowed everywhere.
#
# Registered on matcher "Agent" in claude-code-settings.json PreToolUse.
#
# Responds to CLAUDE_ROLE (Claude Code) and PI_ROLE (PI harness)
# via resolve_role() — precedence: CLAUDE_ROLE > PI_ROLE.

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
source "$(dirname "$0")/_role.sh"
parse_input

# Only guard the Agent tool (subagent spawn).
if [ "$TOOL_NAME" != "Agent" ]; then
    exit 0
fi

subagent_type=$(printf '%s' "$RAW_INPUT" | jq -r '.tool_input.subagent_type // ""' 2>/dev/null)
isolation=$(printf '%s' "$RAW_INPUT" | jq -r '.tool_input.isolation // ""' 2>/dev/null || true)
if [ "$isolation" = "worktree" ]; then
    deny 'BLOCKED by operator-subagent-allowlist: Agent-tool isolation:"worktree" is never valid for a codegen subagent — builds operate on the shared checkout. For an isolated worktree, use the native launcher flow (claude --worktree <name>), not the Agent isolation parameter.'
    exit 0
fi
_role=$(resolve_role)

debug_log operator-subagent-allowlist "role=${_role} subagent_type=$subagent_type"

# Built-in subagent types — denied in all launcher modes.
if [ "$subagent_type" = "Plan" ] || [ "$subagent_type" = "general-purpose" ] || [ "$subagent_type" = "statusline-setup" ]; then
    deny "BLOCKED by operator-subagent-allowlist: built-in subagent $subagent_type is denied in all launcher modes. Valid project subagents in build mode: planner-phoenix / planner-static / etc., developer-*, reviewer-*, committer. Use planner-<stack> for planning, not the built-in Plan."
    exit 0
fi

# Empty subagent_type — deny defensively (fail-closed).
if [ -z "$subagent_type" ]; then
    deny "BLOCKED by operator-subagent-allowlist: subagent_type is empty — cannot determine safe subagent. Specify a named project subagent. Valid project subagents in build mode: planner-phoenix / planner-static / etc., developer-*, reviewer-*, committer. Use planner-<stack> for planning, not the built-in Plan."
    exit 0
fi

# Explore — allowed only under debug/shape/ops operator roles.
if [ "$subagent_type" = "Explore" ]; then
    if [ "$_role" = "debug" ] || [ "$_role" = "shape" ] || [ "$_role" = "ops" ]; then
        exit 0
    fi
    deny "BLOCKED by operator-subagent-allowlist: Explore subagent is only available under claude-debug, claude-shape, or claude-ops launcher modes. Use planner-phoenix / planner-static / etc. instead for investigation within a standard orchestrator session."
    exit 0
fi

# Shape mode is read-only — deny source-editing subagents.
if [ "$_role" = "shape" ]; then
    case "$subagent_type" in
    developer-* | reviewer-* | committer)
        deny "BLOCKED by operator-subagent-allowlist: shaping modes are read-only — they investigate and write pitches; spawn a builder from build mode instead. Available in shape mode: planner-phoenix / planner-static / etc. and Explore; developer-*/reviewer-*/committer are build-mode only."
        exit 0
        ;;
    esac
fi

# All other subagent types (project subagents) — allow.
exit 0
