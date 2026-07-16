#!/usr/bin/env bash
# Pi babysit launcher — analogous to pi-ops.sh / claude-babysit.sh.
#
# PI_ROLE=babysit is exported before exec.
# Tool surface: read,grep,find,ls,edit,write,bash — interactive drain
# supervisor dispatching the EXISTING codegen-build --queue drain and
# claude-shape entrypoint on a recurring cadence.
# --studio routes the drain to the resolved codegen-studio ssh target.
set -euo pipefail

if ! command -v pi >/dev/null 2>&1; then
    echo "ERROR: 'pi' binary not found in PATH." >&2
    echo "Install: npm install -g @earendil-works/pi-coding-agent" >&2
    echo "See README.md § Prerequisites for details." >&2
    exit 127
fi

export PI_ROLE=babysit

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -n "${OCG_CODEGEN_DIR:-}" ]]; then
    CODEGEN_DIR="$OCG_CODEGEN_DIR"
elif [[ -L "$SCRIPT_DIR/harnesses" || -d "$SCRIPT_DIR/harnesses" ]]; then
    CODEGEN_DIR="$(cd -P "$SCRIPT_DIR/harnesses" && cd .. && pwd)"
else
    CODEGEN_DIR="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
fi
export CODEGEN_DIR

SYSTEM_PROMPT_FILE="$CODEGEN_DIR/harnesses/pi/pi-babysit-system-prompt.txt"
if [ ! -f "$SYSTEM_PROMPT_FILE" ]; then
    echo "ERROR: pi-babysit-system-prompt.txt not found at $SYSTEM_PROMPT_FILE" >&2
    exit 1
fi
ROLE_SYSTEM_PROMPT=$(cat "$SYSTEM_PROMPT_FILE")

cfg="${CODEGEN_DIR}/templates/generator/config.yaml"
ROLE_MODEL=$(yq -r ".harness.babysit.pi.model" "$cfg")
ROLE_EFFORT=$(yq -r ".harness.babysit.pi.effort" "$cfg")

STUDIO=0
for _a in "$@"; do
    if [[ "$_a" == "--studio" ]]; then
        STUDIO=1
    fi
done

BABYSIT_STARTUP='## BABYSIT STARTUP CONTEXT'
if [[ "$STUDIO" -eq 1 ]]; then
    export CODEGEN_BABYSIT_STUDIO=1
    source "$CODEGEN_DIR/harnesses/claude/ssh-target.sh"

    [[ -n "${PI_NON_INTERACTIVE:-}" ]] && export SSH_TARGET_NON_INTERACTIVE=1

    resolve_ssh_target studio BABYSIT pi-babysit

    BABYSIT_STARTUP="${BABYSIT_STARTUP}
Target: STUDIO — ${BABYSIT_ALIAS} (${server_resolved}), Login user: ${BABYSIT_LOGIN_USER}, Operate-as: ${BABYSIT_OPERATE_AS}. Before your FIRST dispatch to this target, run the remote build-ready preflight and refuse to dispatch remotely if it is red."
else
    BABYSIT_STARTUP="${BABYSIT_STARTUP}
Target: LOCAL — dispatch codegen-build --queue and claude-shape in this checkout."
fi

ROLE_SYSTEM_PROMPT="${ROLE_SYSTEM_PROMPT}

${BABYSIT_STARTUP}"

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
