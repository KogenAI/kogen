#!/usr/bin/env bash
# Pi design launcher — analogous to claude-design.sh.
#
# PI_ROLE=design is exported before exec.
# Tool surface: read,grep,find,ls,edit,write,bash — agent instructed via system
# prompt to write only under codegen/designs/. No native PreToolUse hook mechanism
# in Pi; enforcement is coarser (tool allowlist + system-prompt instruction).
# PROJECT_CONTEXT.md appended to system prompt when present (mirrors claude-design.sh).
# Interactive mode: user types prompts in the TUI.
set -euo pipefail
export PI_ROLE=design

CODEGEN_DIR="${OCG_CODEGEN_DIR:-$HOME/Areas/Optimum/codegen}"
export CODEGEN_DIR

SYSTEM_PROMPT_FILE="$CODEGEN_DIR/templates/shared/pi-design-system-prompt.txt"
if [ ! -f "$SYSTEM_PROMPT_FILE" ]; then
    echo "ERROR: pi-design-system-prompt.txt not found at $SYSTEM_PROMPT_FILE" >&2
    exit 1
fi
ROLE_SYSTEM_PROMPT=$(cat "$SYSTEM_PROMPT_FILE")

# Append PROJECT_CONTEXT.md when present (same deep-context preload as claude-design).
if [[ -f "./PROJECT_CONTEXT.md" ]]; then
    ROLE_SYSTEM_PROMPT="${ROLE_SYSTEM_PROMPT}

$(cat ./PROJECT_CONTEXT.md)"
fi

cfg="${CODEGEN_DIR}/templates/generator/config.yaml"
ROLE_MODEL=$(yq -r ".harness.inspector.pi.model" "$cfg")
ROLE_EFFORT=$(yq -r ".harness.inspector.pi.effort" "$cfg")

exec pi \
    --provider openai-codex \
    --model "$ROLE_MODEL" \
    --thinking "$ROLE_EFFORT" \
    --tools read,grep,find,ls,edit,write,bash \
    --system-prompt "$ROLE_SYSTEM_PROMPT" \
    "$@"
