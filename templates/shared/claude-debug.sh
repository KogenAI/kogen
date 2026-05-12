#!/usr/bin/env bash
set -euo pipefail

CODEGEN_DIR="${OCG_CODEGEN_DIR:-$HOME/Areas/Optimum/codegen}"
PROMPT_FILE="$CODEGEN_DIR/templates/shared/claude-debug-system-prompt.txt"

exec claude \
    --model sonnet \
    --effort medium \
    --dangerously-skip-permissions \
    --disallowed-tools EnterPlanMode,ExitPlanMode,EnterWorktree \
    --system-prompt "$(cat "$PROMPT_FILE")" \
    "$@"
