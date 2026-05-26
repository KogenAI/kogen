#!/usr/bin/env bash
# harnesses/pi/dispatch.sh — Pi harness dispatch for codegen-build.
#
# Called by codegen-build with extra flags + prompt as positional args.
# stdout is byte-transparent (pi JSONL). STDERR: diagnostics only.

set -euo pipefail

# Consume env vars set by codegen-build
MODEL="${CODEGEN_BUILD_MODEL:-}"
EFFORT="${CODEGEN_BUILD_EFFORT:-}"
NON_INTERACTIVE="${CODEGEN_BUILD_NON_INTERACTIVE:-}"

# Fall back to config.yaml values if not set
if [[ -z "$MODEL" || -z "$EFFORT" ]]; then
    CODEGEN_DIR="${OCG_CODEGEN_DIR:-$HOME/Areas/Optimum/codegen}"
    cfg="$CODEGEN_DIR/templates/generator/config.yaml"
    if [[ -f "$cfg" ]]; then
        [[ -z "$MODEL" ]] && MODEL=$(yq -r ".harness.build.pi.model" "$cfg" 2>/dev/null || echo "")
        [[ -z "$EFFORT" ]] && EFFORT=$(yq -r ".harness.build.pi.effort" "$cfg" 2>/dev/null || echo "")
    fi
fi

MODEL="${MODEL:-openai-codex/gpt-5.4-mini}"
EFFORT="${EFFORT:-high}"

# Extra flags and prompt: last positional arg is always the PROMPT
PROMPT="${*: -1}"
EXTRA_FLAGS=()
EXTENSION_ARG=()

if [[ $# -gt 1 ]]; then
    for ((i = 1; i < $#; i++)); do
        arg="${!i}"
        if [[ "$arg" == --extension=* ]]; then
            EXTENSION_ARG+=(--extension "${arg#--extension=}")
        elif [[ "$arg" == --extension ]]; then
            next_idx=$((i + 1))
            EXTENSION_ARG+=(--extension "${!next_idx}")
            i=$next_idx
        else
            EXTRA_FLAGS+=("$arg")
        fi
    done
fi

PRINT_FLAG=()
if [[ -n "$NON_INTERACTIVE" ]]; then
    PRINT_FLAG+=(-p)
fi

exec env \
    -u OPENAI_API_KEY \
    -u ANTHROPIC_API_KEY \
    -u CURSOR_API_KEY \
    pi \
    "${PRINT_FLAG[@]+"${PRINT_FLAG[@]}"}" \
    --mode json \
    --no-session \
    --no-context-files \
    "${EXTENSION_ARG[@]+"${EXTENSION_ARG[@]}"}" \
    --provider openai-codex \
    --model "$MODEL" \
    --thinking "$EFFORT" \
    "${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"}" \
    "$PROMPT"
