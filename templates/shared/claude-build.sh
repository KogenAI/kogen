#!/usr/bin/env bash
# See context/claude-code-cli.md for:
#   - what --tools actually controls (built-in tools, NOT subagents)
#   - how the Agent tool is gated to only project subagents
#   - which built-in subagents are denied (Plan, general-purpose, statusline-setup
#     always; Explore allowed only under CLAUDE_ROLE=debug/design)
set -euo pipefail
CODEGEN_DIR="${OCG_CODEGEN_DIR:-$HOME/Areas/Optimum/codegen}"
export CODEGEN_DIR

source "$CODEGEN_DIR/templates/shared/load-role.sh"
load_role build

cfg="${CODEGEN_DIR}/templates/generator/config.yaml"
ROLE_MODEL=$(yq -r ".harness.build.claude.model" "$cfg")
ROLE_EFFORT=$(yq -r ".harness.build.claude.effort" "$cfg")

TOOL_FLAGS=()
if [ -n "$ROLE_TOOLS" ]; then
    TOOL_FLAGS+=(--tools "$ROLE_TOOLS")
elif [ -n "$ROLE_DISALLOWED" ]; then
    TOOL_FLAGS+=(--disallowed-tools "$ROLE_DISALLOWED")
fi

# Transform .md args to @-mentions for auto-load
PROMPT_PARTS=()
for arg in "$@"; do
  if [[ "$arg" == *.md ]]; then
    PROMPT_PARTS+=("@$arg")
  else
    PROMPT_PARTS+=("$arg")
  fi
done

exec claude \
    --model "$ROLE_MODEL" \
    --effort "$ROLE_EFFORT" \
    --dangerously-skip-permissions \
    "${TOOL_FLAGS[@]+"${TOOL_FLAGS[@]}"}" \
    --system-prompt "$ROLE_SYSTEM_PROMPT" \
    "${PROMPT_PARTS[@]+"${PROMPT_PARTS[@]}"}"
