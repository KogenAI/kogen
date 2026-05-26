#!/usr/bin/env bash
# See context/claude-code-cli.md for:
#   - what --tools actually controls (built-in tools, NOT subagents)
#   - how the Agent tool is gated to only project subagents
#   - which built-in subagents are denied (Plan, general-purpose, statusline-setup
#     always; Explore allowed only under CLAUDE_ROLE=debug/shape/refactor)
set -euo pipefail
export CLAUDE_ROLE=debug

CODEGEN_DIR="${OCG_CODEGEN_DIR:-$HOME/Areas/Optimum/codegen}"
export CODEGEN_DIR

source "$CODEGEN_DIR/harnesses/claude/load-role.sh"
load_role debug

CONTEXT_FLAGS=()
if [[ -f "./PROJECT_CONTEXT.md" ]]; then
    CONTEXT_FLAGS+=(--append-system-prompt "$(cat ./PROJECT_CONTEXT.md)")
fi

TOOL_FLAGS=()
if [ -n "$ROLE_TOOLS" ]; then
    TOOL_FLAGS+=(--tools "$ROLE_TOOLS")
elif [ -n "$ROLE_DISALLOWED" ]; then
    TOOL_FLAGS+=(--disallowed-tools "$ROLE_DISALLOWED")
fi

exec claude \
    --model "$ROLE_MODEL" \
    --effort "$ROLE_EFFORT" \
    --dangerously-skip-permissions \
    "${TOOL_FLAGS[@]+"${TOOL_FLAGS[@]}"}" \
    --system-prompt "$ROLE_SYSTEM_PROMPT" \
    "${CONTEXT_FLAGS[@]+"${CONTEXT_FLAGS[@]}"}" \
    "$@"
