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

# --draft <path> "text" — capture-append mode: swaps system prompt, skips
# shaping/readiness loop, Tier-0/Tier-1 context loads, and pitch resolver.
# Pre-scan and strip BEFORE anything else so --draft is never misread as a pitch arg.
DRAFT_PATH=""
DRAFT_TEXT=""
_FILTERED_ARGS=()
_i=0
_args=("$@")
while [[ $_i -lt ${#_args[@]} ]]; do
    _arg="${_args[$_i]}"
    if [[ "$_arg" == "--draft" ]]; then
        _next=$((_i + 1))
        _after=$((_i + 2))
        if [[ $_next -ge ${#_args[@]} ]]; then
            printf 'pi-shape: --draft requires <path> "text"\n' >&2
            exit 2
        fi
        DRAFT_PATH="${_args[$_next]}"
        if [[ $_after -lt ${#_args[@]} ]]; then
            DRAFT_TEXT="${_args[$_after]}"
            _i=$((_after + 1))
        else
            _i=$((_next + 1))
        fi
    else
        _FILTERED_ARGS+=("$_arg")
        _i=$((_i + 1))
    fi
done

if [[ -n "$DRAFT_PATH" ]]; then
    if [[ ! -f "$DRAFT_PATH" ]]; then
        printf 'pi-shape: --draft path not found: %s\n' "$DRAFT_PATH" >&2
        exit 1
    fi
    if [[ -z "$DRAFT_TEXT" ]]; then
        printf 'pi-shape: --draft requires text argument: --draft <path> "text"\n' >&2
        exit 2
    fi

    cfg="${CODEGEN_DIR}/templates/generator/config.yaml"
    ROLE_MODEL=$(yq -r ".harness.shape.pi.model" "$cfg")
    ROLE_EFFORT=$(yq -r ".harness.shape.pi.effort" "$cfg")

    ROLE_SYSTEM_PROMPT="$(cat "$CODEGEN_DIR/harnesses/shared/prompt-bodies/shape-draft.txt")

---
TARGET PATH: $DRAFT_PATH
TEXT TO APPEND:
$DRAFT_TEXT"

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
fi

set -- "${_FILTERED_ARGS[@]+"${_FILTERED_ARGS[@]}"}"

# Normalise launch cwd to the nearest legal pitch root so the resolver, the
# CLAUDE_PITCH_PATH export, and the session cwd inherited by claude all key off
# a dir whose ./codegen/pitches/draft is the intended target. A nested $PWD
# (e.g. inside codegen/pitches) otherwise mis-resolves and the write-scope
# guard denies the legitimate pitch write. claude has no --cwd flag — cd + exec
# is the only reliable way (mirrors dispatch.sh).
resolve_pitch_root() {
    case "$1" in
    */codegen/pitches/*) printf '%s' "${1%%/codegen/pitches/*}" ;;
    */codegen/pitches) printf '%s' "${1%/codegen/pitches}" ;;
    *) printf '%s' "$1" ;;
    esac
}
PITCH_ROOT="$(resolve_pitch_root "$PWD")"
if [[ "$PITCH_ROOT" != "$PWD" ]]; then
    printf 'pi-shape: launched inside codegen/pitches; using repo root %s\n' "$PITCH_ROOT" >&2
    cd "$PITCH_ROOT"
fi

SYSTEM_PROMPT_FILE="$CODEGEN_DIR/harnesses/pi/pi-shape-system-prompt.txt"
if [ ! -f "$SYSTEM_PROMPT_FILE" ]; then
    echo "ERROR: pi-shape-system-prompt.txt not found at $SYSTEM_PROMPT_FILE" >&2
    exit 1
fi
ROLE_SYSTEM_PROMPT=$(cat "$SYSTEM_PROMPT_FILE")

# Append PROJECT_CONTEXT.md when present (same deep-context preload as claude-shape).
TIER0_LOADED=""
if [[ -f "./PROJECT_CONTEXT.md" ]]; then
    ROLE_SYSTEM_PROMPT="${ROLE_SYSTEM_PROMPT}

$(cat ./PROJECT_CONTEXT.md)"
    # Tier 0: foundational docs listed under "## Always Load" in the index.
    # Read each basename, append context/<name> if it exists. Fail-open.
    _in_always=0
    while IFS= read -r _line; do
        case "$_line" in
        "## Always Load")
            _in_always=1
            continue
            ;;
        "## "*) [[ $_in_always -eq 1 ]] && break ;;
        esac
        [[ $_in_always -eq 1 ]] || continue
        case "$_line" in
        "- "*)
            _bn="${_line#- }"
            _bn="${_bn%% *}"
            [[ -n "$_bn" ]] || continue
            if [[ -f "./context/$_bn" ]]; then
                ROLE_SYSTEM_PROMPT="${ROLE_SYSTEM_PROMPT}
$(cat "./context/$_bn")"
                TIER0_LOADED="${TIER0_LOADED} ${_bn}"
            else
                printf 'pi-shape: Tier-0 doc context/%s listed in Always Load but not found; skipping\n' "$_bn" >&2
            fi
            ;;
        esac
    done <./PROJECT_CONTEXT.md
fi

# Tier 1: pitch-matched context files from § Domain Context Files table.
# Detect if a single pitch path was passed (mirrors claude-shape.sh logic). Fail-open.
PI_PITCH_PATH=""
if [[ $# -eq 1 ]]; then
    _arg="$1"
    # Resolve bare basename (no / and no .md extension)
    if [[ "$_arg" != */* ]] && [[ "$_arg" != *.md ]] && [[ "$_arg" != *" "* ]]; then
        _draft_dir="$PWD/codegen/pitches/draft"
        if [[ -f "$_draft_dir/${_arg}.md" ]]; then
            PI_PITCH_PATH="$_draft_dir/${_arg}.md"
        fi
    elif [[ -f "$_arg" ]]; then
        PI_PITCH_PATH="$_arg"
    fi
fi
if [[ -n "$PI_PITCH_PATH" && -f "./PROJECT_CONTEXT.md" ]]; then
    _tier1_count=0
    _in_table=0
    while IFS='|' read -r _pre _file _domain _ids _rest; do
        case "$_file" in
        *"context/"*.md*)
            [[ $_in_table -eq 0 ]] && _in_table=1
            ;;
        *"File"* | *"---"*)
            continue
            ;;
        *)
            continue
            ;;
        esac
        _ctx_file="${_file//\`/}"
        _ctx_file="${_ctx_file## }"
        _ctx_file="${_ctx_file%% }"
        _ctx_bn="${_ctx_file##*/}"
        case "$TIER0_LOADED" in
        *" ${_ctx_bn}"*) continue ;;
        esac
        [[ -f "./${_ctx_file}" ]] || continue
        _matched=0
        IFS=',' read -ra _id_arr <<<"$_ids"
        for _id in "${_id_arr[@]}"; do
            _id="${_id## }"
            _id="${_id%% }"
            [[ -z "$_id" ]] && continue
            if grep -qiF "$_id" "$PI_PITCH_PATH" 2>/dev/null; then
                _matched=1
                break
            fi
        done
        if [[ $_matched -eq 1 ]]; then
            if [[ $_tier1_count -lt 6 ]]; then
                ROLE_SYSTEM_PROMPT="${ROLE_SYSTEM_PROMPT}
$(cat "./${_ctx_file}")"
                _tier1_count=$((_tier1_count + 1))
            else
                printf 'pi-shape: Tier-1 cap (6) reached; skipping context/%s\n' "$_ctx_bn" >&2
            fi
        fi
    done <./PROJECT_CONTEXT.md
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
