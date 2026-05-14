#!/usr/bin/env bash
set -euo pipefail
export CLAUDE_ROLE=user_app_build

CODEGEN_DIR="${OCG_CODEGEN_DIR:-$HOME/Areas/Optimum/codegen}"
export CODEGEN_DIR

source "$CODEGEN_DIR/templates/shared/load-role.sh"
load_role build

cfg="${CODEGEN_DIR}/templates/generator/config.yaml"
ROLE_MODEL=$(yq -r ".harness.build.claude.model" "$cfg")
ROLE_EFFORT=$(yq -r ".harness.build.claude.effort" "$cfg")

CONTEXT_FLAGS=()
if [[ -f "./PROJECT_CONTEXT.md" ]]; then
    CONTEXT_FLAGS+=(--append-system-prompt "$(cat ./PROJECT_CONTEXT.md)")
fi

exec claude \
    --model "$ROLE_MODEL" \
    --effort "$ROLE_EFFORT" \
    --dangerously-skip-permissions \
    --disallowed-tools "$ROLE_DISALLOWED" \
    --system-prompt "$ROLE_SYSTEM_PROMPT" \
    "${CONTEXT_FLAGS[@]+"${CONTEXT_FLAGS[@]}"}" \
    "$@"
