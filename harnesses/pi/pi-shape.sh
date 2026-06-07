#!/usr/bin/env bash
# Pi shape launcher — analogous to claude-shape.sh.
#
# PI_ROLE=shape is exported before exec.
# Tool surface: read,grep,find,ls,edit,write,bash — agent instructed via system
# prompt to write only under codegen/pitches/. No native PreToolUse hook mechanism
# in Pi; enforcement is coarser (tool allowlist + system-prompt instruction).
# PROJECT_CONTEXT.md appended to system prompt when present (mirrors claude-shape.sh).
# Interactive mode: user types prompts in the TUI.
set -euo pipefail

if ! command -v pi >/dev/null 2>&1; then
    echo "ERROR: 'pi' binary not found in PATH." >&2
    echo "Install: npm install -g @earendil-works/pi-coding-agent" >&2
    echo "See README.md § Prerequisites for details." >&2
    exit 127
fi

export PI_ROLE=shape

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -n "${OCG_CODEGEN_DIR:-}" ]]; then
    CODEGEN_DIR="$OCG_CODEGEN_DIR"
elif [[ -L "$SCRIPT_DIR/harnesses" || -d "$SCRIPT_DIR/harnesses" ]]; then
    CODEGEN_DIR="$(cd -P "$SCRIPT_DIR/harnesses" && cd .. && pwd)"
else
    CODEGEN_DIR="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
fi
export CODEGEN_DIR

SYSTEM_PROMPT_FILE="$CODEGEN_DIR/harnesses/pi/pi-shape-system-prompt.txt"
if [ ! -f "$SYSTEM_PROMPT_FILE" ]; then
    echo "ERROR: pi-shape-system-prompt.txt not found at $SYSTEM_PROMPT_FILE" >&2
    exit 1
fi
ROLE_SYSTEM_PROMPT=$(cat "$SYSTEM_PROMPT_FILE")

# Append PROJECT_CONTEXT.md when present (same deep-context preload as claude-shape).
if [[ -f "./PROJECT_CONTEXT.md" ]]; then
    ROLE_SYSTEM_PROMPT="${ROLE_SYSTEM_PROMPT}

$(cat ./PROJECT_CONTEXT.md)"
fi

cfg="${CODEGEN_DIR}/templates/generator/config.yaml"
ROLE_MODEL=$(yq -r ".harness.shape.pi.model" "$cfg")
ROLE_EFFORT=$(yq -r ".harness.shape.pi.effort" "$cfg")

EXTENSIONS_DIR="$CODEGEN_DIR/harnesses/pi/pi-extensions"

NON_INTERACTIVE_FLAGS=()
if [[ -n "${PI_NON_INTERACTIVE:-}" ]]; then
    NON_INTERACTIVE_FLAGS+=(-p --mode text --no-session)
fi

exec pi \
    "${NON_INTERACTIVE_FLAGS[@]+"${NON_INTERACTIVE_FLAGS[@]}"}" \
    --provider openai-codex \
    --model "$ROLE_MODEL" \
    --thinking "$ROLE_EFFORT" \
    --tools read,grep,find,ls,edit,write,bash \
    --no-extensions \
    --extension "$EXTENSIONS_DIR/askuserquestion" \
    --extension "$EXTENSIONS_DIR/subagents" \
    --extension "$EXTENSIONS_DIR/web-utils" \
    --system-prompt "$ROLE_SYSTEM_PROMPT" \
    "$@"
