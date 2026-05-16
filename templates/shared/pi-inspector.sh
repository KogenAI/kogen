#!/usr/bin/env bash
# Pi inspector launcher — analogous to claude-debug.sh (inspector mode).
#
# PI_ROLE=inspector is exported before exec.
# Tool surface restricted via --tools allowlist + -nt (no-tools base) so only
# read,grep,find,ls are available. No edit/write tools — enforcement at CLI level.
# Interactive mode: user types prompts in the TUI.
set -euo pipefail
export PI_ROLE=inspector

CODEGEN_DIR="${OCG_CODEGEN_DIR:-$HOME/Areas/Optimum/codegen}"
export CODEGEN_DIR

SYSTEM_PROMPT_FILE="$CODEGEN_DIR/templates/shared/pi-inspector-system-prompt.txt"
if [ ! -f "$SYSTEM_PROMPT_FILE" ]; then
    echo "ERROR: pi-inspector-system-prompt.txt not found at $SYSTEM_PROMPT_FILE" >&2
    exit 1
fi
ROLE_SYSTEM_PROMPT=$(cat "$SYSTEM_PROMPT_FILE")

cfg="${CODEGEN_DIR}/templates/generator/config.yaml"
ROLE_MODEL=$(yq -r ".harness.inspector.pi.model" "$cfg")
ROLE_EFFORT=$(yq -r ".harness.inspector.pi.effort" "$cfg")

exec pi \
    --provider openai-codex \
    --model "$ROLE_MODEL" \
    --thinking "$ROLE_EFFORT" \
    --tools read,grep,find,ls \
    -nt \
    --system-prompt "$ROLE_SYSTEM_PROMPT" \
    "$@"
