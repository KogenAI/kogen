#!/usr/bin/env bash
# Pi debug launcher — analogous to claude-debug.sh (debug/investigation mode).
#
# PI_ROLE=debug is exported before exec.
# Tool surface restricted via --tools allowlist + -nt (no-tools base) so only
# read,grep,find,ls are available. No edit/write tools — enforcement at CLI level.
# Interactive mode: user types prompts in the TUI.
set -euo pipefail

if ! command -v pi >/dev/null 2>&1; then
    echo "ERROR: 'pi' binary not found in PATH." >&2
    echo "Install: npm install -g @earendil-works/pi-coding-agent" >&2
    echo "See README.md § Prerequisites for details." >&2
    exit 127
fi

export PI_ROLE=debug

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -n "${OCG_CODEGEN_DIR:-}" ]]; then
    CODEGEN_DIR="$OCG_CODEGEN_DIR"
elif [[ -L "$SCRIPT_DIR/harnesses" || -d "$SCRIPT_DIR/harnesses" ]]; then
    CODEGEN_DIR="$(cd -P "$SCRIPT_DIR/harnesses" && cd .. && pwd)"
else
    CODEGEN_DIR="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
fi
export CODEGEN_DIR

SYSTEM_PROMPT_FILE="$CODEGEN_DIR/harnesses/pi/pi-debug-system-prompt.txt"
if [ ! -f "$SYSTEM_PROMPT_FILE" ]; then
    echo "ERROR: pi-debug-system-prompt.txt not found at $SYSTEM_PROMPT_FILE" >&2
    exit 1
fi
ROLE_SYSTEM_PROMPT=$(cat "$SYSTEM_PROMPT_FILE")

cfg="${CODEGEN_DIR}/templates/generator/config.yaml"
ROLE_MODEL=$(yq -r ".harness.debug.pi.model" "$cfg")
ROLE_EFFORT=$(yq -r ".harness.debug.pi.effort" "$cfg")

source "$CODEGEN_DIR/harnesses/shared/mode-context.sh"
resolve_mode_context debug
while IFS= read -r _cf; do
    [ -n "$_cf" ] || continue
    ROLE_SYSTEM_PROMPT="${ROLE_SYSTEM_PROMPT}"$'\n\n'"$(cat "$CODEGEN_DIR/$_cf")"
done <<<"$ROLE_CONTEXT_FILES"

DEBUG_CONTEXT="Host: $(hostname 2>/dev/null || echo unknown), Login user: $(id -un 2>/dev/null || echo unknown), Working dir: ${PWD}"

# Append DEBUG_CONTEXT to system prompt (mirrors pi-ops.sh OPS_CONTEXT pattern;
# content mirrors claude-debug.sh's DEBUG_STARTUP_MSG structure, adapted for the
# local (non-SSH) debug launcher — pi-debug takes a prompt arg, not a server).
ROLE_SYSTEM_PROMPT="${ROLE_SYSTEM_PROMPT}

## DEBUG STARTUP CONTEXT
${DEBUG_CONTEXT}

## Pre-flight self-check
Before investigating, confirm the working directory holds the project you expect:
  ls ${PWD}
If the contents look wrong, stop and report to the user — do not proceed on guesswork.
Once oriented: read logs and config; do NOT run mutations (this launcher is read-only: tools are read,grep,find,ls)."

EXTENSIONS_DIR="$CODEGEN_DIR/harnesses/pi/pi-extensions"

NON_INTERACTIVE_FLAGS=()
if [[ -n "${PI_NON_INTERACTIVE:-}" ]]; then
    NON_INTERACTIVE_FLAGS+=(-p --mode text --no-session)
fi

exec pi \
    "${NON_INTERACTIVE_FLAGS[@]+"${NON_INTERACTIVE_FLAGS[@]}"}" \
    --model "$ROLE_MODEL" \
    --thinking "$ROLE_EFFORT" \
    --tools read,grep,find,ls \
    -nt \
    --no-extensions \
    --extension "$EXTENSIONS_DIR/subagents" \
    --system-prompt "$ROLE_SYSTEM_PROMPT" \
    "$@"
