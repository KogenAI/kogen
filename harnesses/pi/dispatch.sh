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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
CODEGEN_DIR="${OCG_CODEGEN_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd -P)}"

SP_FILE="$SCRIPT_DIR/pi-build-system-prompt.txt"
if [[ ! -f "$SP_FILE" ]]; then
    printf 'pi dispatch: system prompt file not found at %s\n' "$SP_FILE" >&2
    exit 2
fi
SYSTEM_PROMPT_FLAG=(--system-prompt "$(cat "$SP_FILE")")

MANIFEST="$SCRIPT_DIR/manifest.yaml"
if [[ ! -f "$MANIFEST" ]]; then
    printf 'pi dispatch: manifest not found at %s\n' "$MANIFEST" >&2
    exit 1
fi
if ! command -v yq >/dev/null 2>&1; then
    printf 'pi dispatch: yq not found on PATH (required to read %s)\n' "$MANIFEST" >&2
    exit 2
fi
DEFAULT_EXTENSION_ARG=()
while IFS= read -r _ext_name; do
    [[ -z "$_ext_name" || "$_ext_name" == "null" ]] && continue
    _ext_path="$CODEGEN_DIR/harnesses/pi/pi-extensions/$_ext_name"
    if [[ ! -d "$_ext_path" ]]; then
        printf 'pi dispatch: extension path not found at %s\n' "$_ext_path" >&2
        exit 1
    fi
    DEFAULT_EXTENSION_ARG+=(--extension "$_ext_path")
done < <(yq -r '.modes.build.extensions[]' "$MANIFEST")

# Consume env vars set by codegen-build
MODEL="${CODEGEN_BUILD_MODEL:-}"
EFFORT="${CODEGEN_BUILD_EFFORT:-}"
NON_INTERACTIVE="${CODEGEN_BUILD_NON_INTERACTIVE:-}"
RESUMABLE="${CODEGEN_BUILD_RESUMABLE:-}"
RESUME_ID="${CODEGEN_BUILD_RESUME_ID:-}"

# Fall back to config.yaml values if not set
if [[ -z "$MODEL" || -z "$EFFORT" ]]; then
    CODEGEN_DIR="${OCG_CODEGEN_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd -P)}"
    cfg="$CODEGEN_DIR/templates/generator/config.yaml"
    if [[ -f "$cfg" ]]; then
        [[ -z "$MODEL" ]] && MODEL=$(yq -r ".harness.build.pi.model" "$cfg")
        [[ -z "$EFFORT" ]] && EFFORT=$(yq -r ".harness.build.pi.effort" "$cfg")
    else
        printf 'pi dispatch: config.yaml not found at %s\n' "$cfg" >&2
        exit 1
    fi
fi

if [[ -z "$MODEL" || "$MODEL" == "null" ]]; then
    printf 'pi dispatch: harness.build.pi.model missing/empty in config.yaml\n' >&2
    exit 1
fi
if [[ -z "$EFFORT" || "$EFFORT" == "null" ]]; then
    printf 'pi dispatch: harness.build.pi.effort missing/empty in config.yaml\n' >&2
    exit 1
fi

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
RESUME_FLAGS=()
if [[ -n "$NON_INTERACTIVE" ]]; then
    NON_INTERACTIVE_FLAGS+=(-p --mode json)
    # Default headless: persistence OFF (--no-session). Resumable opt-in: omit it
    # so the session persists and --session can re-attach.
    if [[ -z "$RESUMABLE" ]]; then
        NON_INTERACTIVE_FLAGS+=(--no-session)
    elif [[ -n "$RESUME_ID" ]]; then
        RESUME_FLAGS+=(--session "$RESUME_ID")
    fi
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
    "${RESUME_FLAGS[@]+"${RESUME_FLAGS[@]}"}" \
    --no-context-files \
    "${DEFAULT_EXTENSION_ARG[@]+"${DEFAULT_EXTENSION_ARG[@]}"}" \
    "${EXTENSION_ARG[@]+"${EXTENSION_ARG[@]}"}" \
    --provider openai-codex \
    --model "$MODEL" \
    --thinking "$EFFORT" \
    "${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"}" \
    ${PROMPT:+"$PROMPT"}
