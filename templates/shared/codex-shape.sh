#!/usr/bin/env bash
# Codex shape launcher — analogous to claude-shape.sh.
#
# CODEX_ROLE=shape is exported before exec so codex-shape-guard.sh (apply_patch
# boundary, per_call_inspector surface) activates correctly.
#
# System prompt injected via -c 'system_prompt="..."' (TOML config override).
# PROJECT_CONTEXT.md appended to system prompt when present (mirrors claude-shape.sh).
# Interactive mode: user types prompts in the TUI.
set -euo pipefail
export CODEX_ROLE=shape

CODEGEN_DIR="${OCG_CODEGEN_DIR:-$HOME/Areas/Optimum/codegen}"
export CODEGEN_DIR

SYSTEM_PROMPT_FILE="$CODEGEN_DIR/templates/shared/codex-shape-system-prompt.txt"
if [ ! -f "$SYSTEM_PROMPT_FILE" ]; then
    echo "ERROR: codex-shape-system-prompt.txt not found at $SYSTEM_PROMPT_FILE" >&2
    exit 1
fi
ROLE_SYSTEM_PROMPT=$(cat "$SYSTEM_PROMPT_FILE")

# Append PROJECT_CONTEXT.md when present (same deep-context preload as claude-shape).
if [[ -f "./PROJECT_CONTEXT.md" ]]; then
    ROLE_SYSTEM_PROMPT="${ROLE_SYSTEM_PROMPT}

$(cat ./PROJECT_CONTEXT.md)"
fi

cfg="${CODEGEN_DIR}/templates/generator/config.yaml"
ROLE_MODEL=$(yq -r ".roles.shape.model" "$cfg")

exec codex \
    -m "$ROLE_MODEL" \
    -c "system_prompt=$(printf '%s' "$ROLE_SYSTEM_PROMPT" | jq -Rs .)" \
    "$@"
