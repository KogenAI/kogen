#!/usr/bin/env bash
set -euo pipefail

CODEGEN_DIR="${OCG_CODEGEN_DIR:-$HOME/Areas/Optimum/codegen}"
PROMPT_FILE="$CODEGEN_DIR/templates/shared/claude-build-system-prompt.txt"

exec claude \
    --model haiku \
    --dangerously-skip-permissions \
    --disallowed-tools EnterPlanMode,ExitPlanMode,EnterWorktree,AskUserQuestion \
    --system-prompt "$(cat "$PROMPT_FILE")" \
    "$@"
