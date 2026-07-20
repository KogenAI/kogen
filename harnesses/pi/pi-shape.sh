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

source "$CODEGEN_DIR/harnesses/shared/pitch-context-selector.sh"

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
# Resolve draft basenames against $PWD/codegen/pitches/draft/ first so the
# context preload keys off the on-disk pitch path instead of the raw launcher arg.
RESOLVED_ARGS=()
PASSTHROUGH_ARGS=()
DRAFT_DIR="$PWD/codegen/pitches/draft"
for arg in "$@"; do
    if [[ "$arg" == */* ]] || [[ "$arg" == *.md ]] || [[ "$arg" == *" "* ]]; then
        PASSTHROUGH_ARGS+=("$arg")
        continue
    fi
    if [[ -f "$DRAFT_DIR/${arg}.md" ]]; then
        RESOLVED_ARGS+=("codegen/pitches/draft/${arg}.md")
        continue
    fi
    matches=()
    if [[ -d "$DRAFT_DIR" ]]; then
        while IFS= read -r -d '' f; do
            bn="$(basename "$f" .md)"
            if [[ "$bn" == "${arg}"* ]]; then
                matches+=("$bn")
            fi
        done < <(find "$DRAFT_DIR" -maxdepth 1 -name "*.md" -print0 2>/dev/null)
    fi
    if [[ ${#matches[@]} -eq 1 ]]; then
        RESOLVED_ARGS+=("codegen/pitches/draft/${matches[0]}.md")
    elif [[ ${#matches[@]} -gt 1 ]]; then
        printf 'pi-shape: ambiguous basename %q; matches:\n' "$arg" >&2
        for m in "${matches[@]+"${matches[@]}"}"; do printf '  %s\n' "$m" >&2; done
        exit 1
    else
        printf 'pi-shape: no draft matching %q in codegen/pitches/draft/\n' "$arg" >&2
        exit 1
    fi
done

PI_PITCH_PATH=""
if [[ ${#RESOLVED_ARGS[@]} -gt 0 ]]; then
    PI_PITCH_PATH="$PWD/${RESOLVED_ARGS[0]}"
fi

PI_PROMPT_ARGS=()
if [[ ${#RESOLVED_ARGS[@]} -gt 0 ]]; then
    PI_PROMPT_ARGS=("shape ${RESOLVED_ARGS[*]}")
    if [[ ${#PASSTHROUGH_ARGS[@]} -gt 0 ]]; then
        PI_PROMPT_ARGS[0]+=" ${PASSTHROUGH_ARGS[*]}"
    fi
else
    PI_PROMPT_ARGS=("${PASSTHROUGH_ARGS[@]+"${PASSTHROUGH_ARGS[@]}"}")
fi

if [[ -n "$PI_PITCH_PATH" && -f "./PROJECT_CONTEXT.md" ]]; then
    _selected=$(select_pitch_context "$PI_PITCH_PATH" \
        "./PROJECT_CONTEXT.md" "." "$TIER0_LOADED" "pi-shape" 6)
    while IFS= read -r _ctx_file; do
        [[ -n "$_ctx_file" ]] || continue
        ROLE_SYSTEM_PROMPT="${ROLE_SYSTEM_PROMPT}
$(cat "./${_ctx_file}")"
    done <<<"$_selected"
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
    --model "$ROLE_MODEL" \
    --thinking "$ROLE_EFFORT" \
    --tools read,grep,find,ls,edit,write,bash \
    --no-extensions \
    --extension "$EXTENSIONS_DIR/askuserquestion" \
    --extension "$EXTENSIONS_DIR/subagents" \
    --extension "$EXTENSIONS_DIR/web-utils" \
    --system-prompt "$ROLE_SYSTEM_PROMPT" \
    "${PI_PROMPT_ARGS[@]+"${PI_PROMPT_ARGS[@]}"}"
