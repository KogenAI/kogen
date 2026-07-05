#!/bin/bash
# orchestrator-no-source-edit.sh — PreToolUse Edit|Write|MultiEdit|NotebookEdit hook.
#
# HOOK-MANIFEST:
# event: PreToolUse
# matcher: Write|Edit|MultiEdit|NotebookEdit
# surface: user_global
# signal: CLAUDE_ROLE_FAMILY
# role: *
# harnesses: claude_code
# rationale: CLAUDE_ROLE_FAMILY-keyed launcher mode guard, Pi has no equivalent launcher concept
# GENERATED FROM shared/enforcement/registry.yaml — DO NOT EDIT
#
# Blocks the orchestrator from editing source files directly.
# Subagents (non-empty agent_id) are allowed under no CLAUDE_ROLE_FAMILY (standard
# orchestrator). Under any operator role (debug, shape) the write surface
# is narrowed for BOTH the orchestrator AND Agent-spawned helpers.
# ops mode has full write surface — no restriction applies.
#
# Responds to CLAUDE_ROLE (Claude Code) and PI_ROLE (PI harness)
# via resolve_role() — precedence: CLAUDE_ROLE > PI_ROLE.

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
source "$(dirname "$0")/_role.sh"
parse_input

role=$(resolve_role)
debug_log orchestrator-no-source-edit "tool=$TOOL_NAME agent_id=$AGENT_ID role=${role}"

# Normalise to a repo-relative path so allowlist patterns match both relative
# and abs-in-cwd forms (deliberate loosening — see session-log.md § Path Discipline).
rel_path=$(repo_relative "$FILE_PATH")

# Ops mode — full write surface, no restriction (interactive ops on live boxes).
if [ "$role" = "ops" ]; then
    exit 0
fi

# Experiment mode — source-writable for the role. Confinement is the native
# claude --worktree the launcher runs in (the hook has no worktree awareness),
# NOT a path restriction. Discard-at-exit is the guardrail. Distinct from the
# debug/shape read-only arm below.
if [ "$role" = "experiment" ]; then
    exit 0
fi

# Debug/shape operators (read-only investigation + pitch authoring).
# Writes scoped to codegen/pitches/ — applies to subagents too,
# so Agent-spawned helpers can't slip writes past the role's boundary.
if [ "$role" = "debug" ] || [ "$role" = "shape" ]; then
    # fail-closed: matcher is Write|Edit|MultiEdit|NotebookEdit (all
    # file-bearing); empty path is anomalous, not a legitimate skip.
    if [ -z "$FILE_PATH" ]; then
        deny "BLOCKED by orchestrator-no-source-edit: empty file path in ${role} mode — file-bearing tool with no resolvable path is anomalous; failing closed."
        exit 0
    fi
    if printf '%s' "$rel_path" | grep -qE '^codegen/pitches/'; then
        exit 0
    fi
    deny "BLOCKED by orchestrator-no-source-edit: ${role} mode may only write to codegen/pitches/ — got $FILE_PATH"
    exit 0
fi

# Subagents under no role (standard orchestrator spawns), and named agents
# invoked via --agent (agent_type set, no agent_id) — pass through. Mirrors
# orchestrator-read-discipline.sh's agent_type bypass.
if [ -n "$AGENT_ID" ] || [ -n "$AGENT_TYPE" ]; then
    exit 0
fi

# Plain orchestrator (no role): writes allowed only under codegen/logging/
# and absolute /tmp/.
# fail-closed: matcher is Write|Edit|MultiEdit|NotebookEdit (all
# file-bearing); empty path is anomalous, not a legitimate skip.
if [ -z "$FILE_PATH" ]; then
    deny "BLOCKED by orchestrator-no-source-edit: empty file path for orchestrator — file-bearing tool with no resolvable path is anomalous; failing closed."
    exit 0
fi
if printf '%s' "$rel_path" | grep -qE '^codegen/logging/'; then
    exit 0
fi
if printf '%s' "$FILE_PATH" | grep -qE '^(/private)?/tmp/'; then
    exit 0
fi
if printf '%s' "$rel_path" | grep -qE '^codegen/pitches/'; then
    exit 0
fi

deny "BLOCKED by orchestrator-no-source-edit: ${role:-orchestrator} may only write to codegen/logging/, codegen/pitches/, or absolute /tmp/ ($FILE_PATH). Delegate source edits to developer-phoenix-backend / developer-phoenix-frontend / developer-static."
exit 0
