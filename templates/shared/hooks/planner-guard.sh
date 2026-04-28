#!/bin/bash
# planner-guard.sh — PreToolUse hook for planner
#
# Blocks file-creation, state-modifying shell commands, and Edit calls on
# non-session-log files when the active agent is "planner".
# The planner's only permitted write action is editing the session log
# under codegen/logging/. All other agents pass through unconditionally.
#
# Exit codes:
#   0 — allow the tool call
#   2 — block the tool call (Claude Code PreToolUse convention)

set -euo pipefail

input=$(cat)

# Parse fields from PreToolUse stdin JSON
tool_name=$(printf '%s' "$input" | jq -r '.tool_name // ""')
command=$(printf '%s' "$input" | jq -r '.tool_input.command // ""')
file_path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // ""')
agent_type=$(printf '%s' "$input" | jq -r '.agent_type // ""')

# Debug logging (opt-in via per-script var or the unified COMBOBULATE_HOOKS_DEBUG flag)
if [ -n "${COMBOBULATE_PLANNER_DEBUG:-}" ] || [ -n "${COMBOBULATE_HOOKS_DEBUG:-}" ]; then
    printf '%s tool=%s agent=%s file=%s cmd=%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        "$tool_name" "$agent_type" "$file_path" "$command" \
        >>/tmp/planner-guard-debug.log 2>/dev/null || true
fi

# Only gate planner; allow all other agents unconditionally
if [ "$agent_type" != "planner" ]; then
    exit 0
fi

# ── Tool-level blocks ─────────────────────────────────────────────────────────

if [ "$tool_name" = "Write" ]; then
    printf 'BLOCKED by planner-guard: tool Write forbidden for planner (planner never creates files — edit the session log via Edit)\n' >&2
    exit 2
fi

if [ "$tool_name" = "MultiEdit" ]; then
    printf 'BLOCKED by planner-guard: tool MultiEdit forbidden for planner (planner never mass-edits files)\n' >&2
    exit 2
fi

if [ "$tool_name" = "EnterPlanMode" ]; then
    printf 'BLOCKED by planner-guard: tool EnterPlanMode forbidden for planner (conflicts with orchestrator flow)\n' >&2
    exit 2
fi

if [ "$tool_name" = "ExitPlanMode" ]; then
    printf 'BLOCKED by planner-guard: tool ExitPlanMode forbidden for planner (conflicts with orchestrator flow)\n' >&2
    exit 2
fi

# ── Edit path block ───────────────────────────────────────────────────────────
# Planner may only Edit session log files under codegen/logging/

if [ "$tool_name" = "Edit" ]; then
    if ! printf '%s' "$file_path" | grep -qE 'codegen/logging/[^/]+\.md$'; then
        printf 'BLOCKED by planner-guard: planner may only Edit session log files under codegen/logging/ (got: %s)\n' \
            "$file_path" >&2
        exit 2
    fi
fi

# ── Bash-pattern blocks ───────────────────────────────────────────────────────

if [ "$tool_name" = "Bash" ]; then

    # mix test — planner doesn't run tests
    if printf '%s' "$command" | grep -qE '\bmix[[:space:]]+test\b'; then
        printf 'BLOCKED by planner-guard: mix test is forbidden for planner (run gates after implementation, not during planning)\n' >&2
        exit 2
    fi

    # mix ecto state-modifying commands
    if printf '%s' "$command" | grep -qE '\bmix[[:space:]]+ecto\.(migrate|reset|drop)\b'; then
        printf 'BLOCKED by planner-guard: mix ecto.migrate/reset/drop is forbidden for planner (state-modifying)\n' >&2
        exit 2
    fi

    # make ci / make llm variants — test/verification gates
    if printf '%s' "$command" | grep -qE '\bmake[[:space:]]+(ci|llm|llm-phoenix|llm-phoenix-seed)\b'; then
        printf 'BLOCKED by planner-guard: make ci/llm/llm-phoenix is forbidden for planner (verification gates belong to verification-engineer)\n' >&2
        exit 2
    fi

    # git state-modification commands
    if printf '%s' "$command" | grep -qE '\bgit[[:space:]]+(add|commit|rm|mv|stash|reset|checkout[[:space:]]+[^[:space:]]+|branch[[:space:]]+(-[dD]|-m|-c|[^-]))\b'; then
        printf 'BLOCKED by planner-guard: git state modification is forbidden for planner (committer owns git)\n' >&2
        exit 2
    fi

    # rm / rmdir / mv on paths outside /tmp/ — prevent accidental file deletion
    if printf '%s' "$command" | grep -qE '\b(rm|rmdir)[[:space:]]+(-[rfRF]+[[:space:]]+)?[^/]'; then
        # Allow if target is relative path under /tmp/ — but can't tell at guard time,
        # so block all rm/rmdir that don't start with /tmp/ in the path argument
        if ! printf '%s' "$command" | grep -qE '\b(rm|rmdir)[[:space:]]+(-[rfRF]+[[:space:]]+)?/tmp/'; then
            printf 'BLOCKED by planner-guard: rm/rmdir outside /tmp/ is forbidden for planner\n' >&2
            exit 2
        fi
    fi

    if printf '%s' "$command" | grep -qE '\bmv[[:space:]]+'; then
        # Block mv unless both source and destination are under /tmp/ or codegen/logging/
        if ! printf '%s' "$command" | grep -qE '\bmv[[:space:]]+(/tmp/|codegen/logging/)'; then
            printf 'BLOCKED by planner-guard: mv outside /tmp/ or codegen/logging/ is forbidden for planner\n' >&2
            exit 2
        fi
    fi

    # Redirect to file outside /tmp/ or codegen/logging/ — prevent writes via shell
    if printf '%s' "$command" | grep -qE '>[[:space:]]*[^/]|>[[:space:]]*/(?!tmp/)'; then
        # Check if the redirect target is to codegen/logging/ or /tmp/
        if ! printf '%s' "$command" | grep -qE '>[[:space:]]*(codegen/logging/|/tmp/)'; then
            printf 'BLOCKED by planner-guard: shell redirect to file outside /tmp/ or codegen/logging/ is forbidden for planner\n' >&2
            exit 2
        fi
    fi

fi

exit 0
