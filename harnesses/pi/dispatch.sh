#!/usr/bin/env bash
# harnesses/pi/dispatch.sh — Pi harness dispatch for codegen-build.
#
# Called by codegen-build with extra flags + prompt as positional args.
# stdout is byte-transparent (pi JSONL). STDERR: diagnostics only.

set -euo pipefail

if ! command -v pi >/dev/null 2>&1; then
    echo "ERROR: 'pi' binary not found in PATH." >&2
    echo "Install: npm install -g @earendil-works/pi-coding-agent" >&2
    echo "See README.md § Prerequisites for details." >&2
    exit 127
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Direct-build prompt (no subagents; pi builds the app itself).
# Note: pi-build-system-prompt.txt is regenerated from tools-header/build.txt
# on `make install` and is dormant for build mode — only the *-direct.txt file
# is consumed by dispatch.
STACK="${CODEGEN_BUILD_STACK:-phoenix}"
SP_FILE="$SCRIPT_DIR/pi-build-system-prompt-direct-${STACK}.txt"
if [[ ! -f "$SP_FILE" ]]; then
  SP_FILE="$SCRIPT_DIR/pi-build-system-prompt-direct-phoenix.txt"
fi
SYSTEM_PROMPT_FLAG=()
if [[ -f "$SP_FILE" ]]; then
    SYSTEM_PROMPT_FLAG+=(--system-prompt "$(cat "$SP_FILE")")
fi

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

# Extra flags and prompt: last positional arg is PROMPT (only if any positional args given)
if [[ $# -gt 0 ]]; then
    PROMPT="${*: -1}"
else
    PROMPT=""
fi
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

# Non-interactive: pass JSON output flags. Interactive: omit (pi handles tty detection).
NON_INTERACTIVE_FLAGS=()
if [[ -n "$NON_INTERACTIVE" ]]; then
    NON_INTERACTIVE_FLAGS+=(-p --mode json --no-session)
fi

# Consume CWD env var set by codegen-build
CWD="${CODEGEN_BUILD_CWD:-}"
if [[ -n "$CWD" ]]; then
    cd "$CWD"
fi

exec env \
    -u OPENAI_API_KEY \
    -u ANTHROPIC_API_KEY \
    -u CURSOR_API_KEY \
    pi \
    "${SYSTEM_PROMPT_FLAG[@]+"${SYSTEM_PROMPT_FLAG[@]}"}" \
    "${NON_INTERACTIVE_FLAGS[@]+"${NON_INTERACTIVE_FLAGS[@]}"}" \
    --no-context-files \
    "${EXTENSION_ARG[@]+"${EXTENSION_ARG[@]}"}" \
    --provider openai-codex \
    --model "$MODEL" \
    --thinking "$EFFORT" \
    "${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"}" \
    ${PROMPT:+"$PROMPT"}
