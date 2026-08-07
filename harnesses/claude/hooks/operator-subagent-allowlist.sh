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
# registration only (hand-authored body) — the registry entry for this hook
# is `kind: registration`, which emits ONLY the settings.json wiring; the
# check logic below is NOT generated and is safe to hand-edit.
#
# Enforces subagent spawn rules across all launcher modes:
#
#   Built-in subagents {Plan, general-purpose, statusline-setup} denied always.
#   Empty subagent_type denied defensively (fail-closed).
#   Explore denied unless active role ∈ {debug, shape, ops, experiment, babysit}.
#   Project subagents (developer-*, reviewer-*, context-curator, etc.) allowed everywhere.
#
#   Shape mode is an ALLOWLIST, not a denylist: exactly {Explore, spike-builder}
#   are permitted; every other subagent_type (developer-*, reviewer-*, any
#   invented/typo'd name) denies. This is deliberate — a denylist here has a
#   fail-open default (any unlisted name falls through to ALLOW), and shape's
#   own membership list mutated repeatedly during a single session. An
#   allowlist is indifferent to that churn.
#
# Registered on matcher "Agent" in claude-code-settings.json PreToolUse.
#
# Responds to CLAUDE_ROLE (Claude Code)
# via resolve_role().

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
    deny "BLOCKED by operator-subagent-allowlist: built-in subagent $subagent_type is denied in all launcher modes. Valid project subagents in build mode: developer-phoenix-backend / developer-static / etc., reviewer-*, context-curator. Use developer-<stack> to do the work, not the built-in Plan."
    exit 0
fi

# Empty subagent_type — deny defensively (fail-closed).
if [ -z "$subagent_type" ]; then
    deny "BLOCKED by operator-subagent-allowlist: subagent_type is empty — cannot determine safe subagent. Specify a named project subagent. Valid project subagents in build mode: developer-phoenix-backend / developer-static / etc., reviewer-*, context-curator. Use developer-<stack> to do the work, not the built-in Plan."
    exit 0
fi

# Explore — allowed only under debug/shape/ops/experiment/babysit operator roles.
if [ "$subagent_type" = "Explore" ]; then
    if [ "$_role" = "debug" ] || [ "$_role" = "shape" ] || [ "$_role" = "ops" ] || [ "$_role" = "experiment" ] || [ "$_role" = "babysit" ]; then
        exit 0
    fi
    deny "BLOCKED by operator-subagent-allowlist: Explore subagent is only available under claude-debug, claude-shape, claude-ops, claude-experiment, or claude-babysit launcher modes. Use developer-phoenix-backend / developer-static / etc. instead for investigation within a standard orchestrator session."
    exit 0
fi

# Shape mode is an ALLOWLIST: exactly {Explore, spike-builder} permitted.
# Explore already exited 0 above via the debug/shape/ops/experiment/babysit
# branch, so by the time we reach here in shape mode, only spike-builder (or
# an unlisted/invented name) remains to classify.
if [ "$_role" = "shape" ]; then
    case "$subagent_type" in
    spike-builder)
        exit 0
        ;;
    *)
        deny "BLOCKED by operator-subagent-allowlist: shape mode allows only Explore and spike-builder subagents. $subagent_type is not permitted — shaping investigates and writes pitches; spike-builder is the sandboxed feasibility-spike builder confined to codegen/pitches/ and absolute /tmp/. Spawn other builders from build mode instead."
        exit 0
        ;;
    esac
fi

# All other subagent types (project subagents) — allow.
exit 0
