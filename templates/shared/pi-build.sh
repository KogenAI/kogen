#!/usr/bin/env bash
# Pi build launcher — analogous to claude-build.sh and codex-build.sh.
#
# PI_ROLE=build is exported before exec so hooks/guards that check PI_ROLE read it.
# Non-interactive execution uses `pi -p --mode json`.
# Model and effort read from config.yaml harness.build.pi block.
set -euo pipefail
export PI_ROLE=build

CODEGEN_DIR="${OCG_CODEGEN_DIR:-$HOME/Areas/Optimum/codegen}"
export CODEGEN_DIR

SYSTEM_PROMPT_FILE="$CODEGEN_DIR/templates/shared/pi-build-system-prompt.txt"
if [ ! -f "$SYSTEM_PROMPT_FILE" ]; then
    echo "ERROR: pi-build-system-prompt.txt not found at $SYSTEM_PROMPT_FILE" >&2
    exit 1
fi
ROLE_SYSTEM_PROMPT=$(cat "$SYSTEM_PROMPT_FILE")

cfg="${CODEGEN_DIR}/templates/generator/config.yaml"
ROLE_MODEL=$(yq -r ".harness.build.pi.model" "$cfg")
ROLE_EFFORT=$(yq -r ".harness.build.pi.effort" "$cfg")

# Transform .md args to @-mentions for auto-load (mirrors claude-build.sh convention).
PROMPT_PARTS=()
for arg in "$@"; do
    if [[ "$arg" == *.md ]]; then
        PROMPT_PARTS+=("@$arg")
    else
        PROMPT_PARTS+=("$arg")
    fi
done

exec pi \
    -p \
    --mode json \
    --no-session \
    --no-context-files \
    --provider openai-codex \
    --model "$ROLE_MODEL" \
    --thinking "$ROLE_EFFORT" \
    --system-prompt "$ROLE_SYSTEM_PROMPT" \
    "${PROMPT_PARTS[@]+"${PROMPT_PARTS[@]}"}"
