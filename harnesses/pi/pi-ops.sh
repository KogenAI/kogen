#!/usr/bin/env bash
# Pi ops launcher — analogous to claude-ops.sh.
#
# PI_ROLE=ops is exported before exec.
# Tool surface: read,grep,find,ls,edit,write,bash — agent instructed via system
# prompt to operate with care on production/staging servers.
# Server resolved via ssh -G; ENV_LABEL derived from arg name.
# OPS_CONTEXT appended to system prompt before exec.
set -euo pipefail

server="${1:?Usage: pi-ops <server>}"

if ! command -v pi >/dev/null 2>&1; then
    echo "ERROR: 'pi' binary not found in PATH." >&2
    echo "Install: npm install -g @earendil-works/pi-coding-agent" >&2
    echo "See README.md § Prerequisites for details." >&2
    exit 127
fi

export PI_ROLE=ops

CODEGEN_DIR="${OCG_CODEGEN_DIR:-$HOME/Areas/Optimum/codegen}"
export CODEGEN_DIR

SYSTEM_PROMPT_FILE="$CODEGEN_DIR/harnesses/pi/pi-ops-system-prompt.txt"
if [ ! -f "$SYSTEM_PROMPT_FILE" ]; then
    echo "ERROR: pi-ops-system-prompt.txt not found at $SYSTEM_PROMPT_FILE" >&2
    exit 1
fi
ROLE_SYSTEM_PROMPT=$(cat "$SYSTEM_PROMPT_FILE")

cfg="${CODEGEN_DIR}/templates/generator/config.yaml"
ROLE_MODEL=$(yq -r ".harness.ops.pi.model" "$cfg")
ROLE_EFFORT=$(yq -r ".harness.ops.pi.effort" "$cfg")

source "$CODEGEN_DIR/harnesses/claude/ssh-target.sh"

# Propagate Pi non-interactive flag to shared helper
[[ -n "${PI_NON_INTERACTIVE:-}" ]] && export SSH_TARGET_NON_INTERACTIVE=1

resolve_ssh_target "$server" OPS pi-ops

OPS_CONTEXT="Server: ${server_resolved} (resolved from '${server}'), Environment: ${ENV_LABEL}"

# Append OPS_CONTEXT to system prompt (mirrors pi-shape.sh PROJECT_CONTEXT pattern)
ROLE_SYSTEM_PROMPT="${ROLE_SYSTEM_PROMPT}

## OPS STARTUP CONTEXT
${OPS_CONTEXT}

Confirm before proceeding."

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
    --system-prompt "$ROLE_SYSTEM_PROMPT"
