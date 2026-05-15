#!/usr/bin/env bash
set -euo pipefail
export CLAUDE_ROLE=multi_step

CODEGEN_DIR="${OCG_CODEGEN_DIR:-$HOME/Areas/Optimum/codegen}"
export CODEGEN_DIR

source "$CODEGEN_DIR/templates/shared/load-role.sh"
load_role multi_step

# Template substitutions for multi-step
CHECKPOINT_FILE="${CHECKPOINT_FILE:-.multi-step-checkpoint.json}"
LOG_PATH="${LOG_PATH:-.multi-step.log}"
STEP_NUM=0
TOTAL_STEPS="?"

SYSTEM_PROMPT=$(sed -e "s|{{CHECKPOINT_FILE}}|$CHECKPOINT_FILE|g" \
    -e "s|{{LOG_PATH}}|$LOG_PATH|g" \
    -e "s|{{STEP}}|$STEP_NUM|g" \
    -e "s|{{TOTAL}}|$TOTAL_STEPS|g" \
    <<<"$ROLE_SYSTEM_PROMPT")

exec claude \
    --model "$ROLE_MODEL" \
    --effort "$ROLE_EFFORT" \
    --dangerously-skip-permissions \
    --disallowed-tools "$ROLE_DISALLOWED" \
    --system-prompt "$SYSTEM_PROMPT" \
    "$@"
