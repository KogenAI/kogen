#!/usr/bin/env bash
set -euo pipefail

CODEGEN_DIR="${OCG_CODEGEN_DIR:-$HOME/Areas/Optimum/codegen}"
PROMPT_FILE="$CODEGEN_DIR/templates/shared/claude-design-system-prompt.txt"

exec claude \
    --model opus \
    --effort high \
    --dangerously-skip-permissions \
    --disallowed-tools EnterPlanMode,ExitPlanMode,EnterWorktree \
    --system-prompt "$(cat "$PROMPT_FILE")" \
    "$@"
