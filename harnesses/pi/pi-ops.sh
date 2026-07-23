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
    echo "Install: run 'make install' in the codegen repo (pins the exact version from harnesses/pi/manifest.yaml)" >&2
    echo "See README.md § Prerequisites for details." >&2
    exit 127
fi

export PI_ROLE=ops

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -n "${OCG_CODEGEN_DIR:-}" ]]; then
    CODEGEN_DIR="$OCG_CODEGEN_DIR"
elif [[ -L "$SCRIPT_DIR/harnesses" || -d "$SCRIPT_DIR/harnesses" ]]; then
    CODEGEN_DIR="$(cd -P "$SCRIPT_DIR/harnesses" && cd .. && pwd)"
else
    CODEGEN_DIR="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
fi
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

source "$CODEGEN_DIR/harnesses/shared/mode-context.sh"
resolve_mode_context ops
while IFS= read -r _cf; do
    [ -n "$_cf" ] || continue
    ROLE_SYSTEM_PROMPT="${ROLE_SYSTEM_PROMPT}"$'\n\n'"$(cat "$CODEGEN_DIR/$_cf")"
done <<<"$ROLE_CONTEXT_FILES"

source "$CODEGEN_DIR/harnesses/shared/ssh-target.sh"

# Propagate Pi non-interactive flag to shared helper
[[ -n "${PI_NON_INTERACTIVE:-}" ]] && export SSH_TARGET_NON_INTERACTIVE=1

resolve_ssh_target "$server" OPS pi-ops

OPS_CONTEXT="Server: ${OPS_ALIAS} (${server_resolved}), Login user: ${OPS_LOGIN_USER}, Operate-as: ${OPS_OPERATE_AS}, Environment: ${ENV_LABEL}"

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

# Deterministic postflight after a clean Pi exit: validates every changed/
# new pitch (ops sessions have full write surface, including
# codegen/pitches/) against the pitch-format grammar. Not `exec` — the
# wrapper must regain control after pi exits to run postflight; it
# preserves pi's own exit code on a non-zero/aborted session.
source "$CODEGEN_DIR/harnesses/shared/pitch-postflight.sh"
run_pitch_postflight ops "$PWD" -- pi \
    "${NON_INTERACTIVE_FLAGS[@]+"${NON_INTERACTIVE_FLAGS[@]}"}" \
    --model "$ROLE_MODEL" \
    --thinking "$ROLE_EFFORT" \
    --tools read,grep,find,ls,edit,write,bash \
    --no-extensions \
    --extension "$EXTENSIONS_DIR/askuserquestion" \
    --extension "$EXTENSIONS_DIR/subagents" \
    --extension "$EXTENSIONS_DIR/web-utils" \
    --system-prompt "$ROLE_SYSTEM_PROMPT"
