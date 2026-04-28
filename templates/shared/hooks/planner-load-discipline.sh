#!/bin/bash
# planner-load-discipline.sh — PreToolUse Read hook scoped to planner.
#
# Blocks the planner from loading implementer-only rule files that are
# already baked into the implementer subagent prompts. Loading them
# wastes tokens and risks the planner over-specifying implementation.
#
# Forbidden basenames (implementer rules):
#   tdd.md, elixir-code-generation.md, phoenix-ui.md, testing-backend.md,
#   git-commit-flow.md, ast-grep-patterns.md
#
# Exit codes:
#   0 — allow the tool call
#   2 — block (Claude Code PreToolUse convention; stderr fed back to model)

set -euo pipefail

input=$(cat)

tool_name=$(printf '%s' "$input" | jq -r '.tool_name // ""')
agent_type=$(printf '%s' "$input" | jq -r '.agent_type // ""')

# Debug logging
if [ -n "${COMBOBULATE_HOOKS_DEBUG:-}" ] || [ -n "${COMBOBULATE_PLD_DEBUG:-}" ]; then
    printf '%s tool=%s agent_type=%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        "$tool_name" "$agent_type" \
        >>/tmp/planner-load-discipline-debug.log 2>/dev/null || true
fi

# Only gate planner
if [ "$agent_type" != "planner" ]; then
    exit 0
fi

if [ "$tool_name" != "Read" ]; then
    exit 0
fi

file_path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // ""')
if [ -z "$file_path" ]; then
    exit 0
fi

# Get basename of the file
basename="${file_path##*/}"

# Check against forbidden implementer rule files
forbidden_list="tdd.md elixir-code-generation.md phoenix-ui.md testing-backend.md git-commit-flow.md ast-grep-patterns.md"
for forbidden in $forbidden_list; do
    if [ "$basename" = "$forbidden" ]; then
        printf 'BLOCKED by planner-load-discipline: planner must not load implementer rules (%s). These are baked into the implementer subagent prompts already.\n' \
            "$basename" >&2
        exit 2
    fi
done

exit 0
