#!/usr/bin/env bash
# Pi experiment launcher — analogous to claude-experiment.sh.
#
# PI_ROLE=experiment is exported before exec.
# Tool surface: read,grep,find,ls,edit,write,bash — agent instructed via system
# prompt to work inside a git worktree add tree and narrate findings to a draft pitch.
# No native --worktree flag in Pi; confinement = tool-allowlist + system-prompt instruction.
# PROJECT_CONTEXT.md appended to system prompt when present (mirrors pi-shape.sh).
# Interactive mode: user types prompts in the TUI.
set -euo pipefail

if ! command -v pi >/dev/null 2>&1; then
    echo "ERROR: 'pi' binary not found in PATH." >&2
    echo "Install: run 'make install' in the codegen repo (pins the exact version from harnesses/pi/manifest.yaml)" >&2
    echo "See README.md § Prerequisites for details." >&2
    exit 127
fi

export PI_ROLE=experiment

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

# --done <slug>: tear down a finished experiment and exit before launch.
if [[ "${1:-}" == "--done" ]]; then
    if [[ -z "${2:-}" ]]; then
        printf 'pi-experiment: --done requires a <slug>\n' >&2
        exit 2
    fi
    source "$CODEGEN_DIR/harnesses/shared/worktree-lifecycle.sh"
    worktree_destroy "$2"
    exit $?
fi

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
    printf 'pi-experiment: launched inside codegen/pitches; using repo root %s\n' "$PITCH_ROOT" >&2
    cd "$PITCH_ROOT"
fi

# Durable main-repo root for pitch writes — the anchor the shared experiment
# prompt-body + /document read. Pi has no native --worktree (the agent self-adds
# one), so cwd stays the main root here, but exporting the same var keeps the
# shared prompt-body's $CODEGEN_PITCH_ROOT reference resolvable across both
# harnesses. dirname of --git-common-dir is the main checkout from anywhere;
# fallback to $PWD if git resolution fails.
export CODEGEN_PITCH_ROOT="$(cd "$(dirname "$(git rev-parse --git-common-dir 2>/dev/null)")" 2>/dev/null && pwd || printf '%s' "$PWD")"

SYSTEM_PROMPT_FILE="$CODEGEN_DIR/harnesses/pi/pi-experiment-system-prompt.txt"
if [ ! -f "$SYSTEM_PROMPT_FILE" ]; then
    echo "ERROR: pi-experiment-system-prompt.txt not found at $SYSTEM_PROMPT_FILE" >&2
    exit 1
fi
ROLE_SYSTEM_PROMPT=$(cat "$SYSTEM_PROMPT_FILE")

# Append PROJECT_CONTEXT.md when present (same deep-context preload as pi-shape).
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
                printf 'pi-experiment: Tier-0 doc context/%s listed in Always Load but not found; skipping\n' "$_bn" >&2
            fi
            ;;
        esac
    done <./PROJECT_CONTEXT.md
fi

# Tier 1: pitch-matched context files from § Domain Context Files table.
# Detect if a single pitch path was passed (mirrors pi-shape.sh logic). Fail-open.
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
    _selected=$(select_pitch_context "$PI_PITCH_PATH" \
        "./PROJECT_CONTEXT.md" "." "$TIER0_LOADED" "pi-experiment" 6)
    while IFS= read -r _ctx_file; do
        [[ -n "$_ctx_file" ]] || continue
        ROLE_SYSTEM_PROMPT="${ROLE_SYSTEM_PROMPT}
$(cat "./${_ctx_file}")"
    done <<<"$_selected"
fi

cfg="${CODEGEN_DIR}/templates/generator/config.yaml"
ROLE_MODEL=$(yq -r ".harness.experiment.pi.model" "$cfg")
ROLE_EFFORT=$(yq -r ".harness.experiment.pi.effort" "$cfg")

EXTENSIONS_DIR="$CODEGEN_DIR/harnesses/pi/pi-extensions"

NON_INTERACTIVE_FLAGS=()
if [[ -n "${PI_NON_INTERACTIVE:-}" ]]; then
    NON_INTERACTIVE_FLAGS+=(-p --mode text --no-session)
fi

# Deterministic postflight after a clean Pi exit: validates every changed/
# new pitch against the pitch-format grammar. Rooted at CODEGEN_PITCH_ROOT
# (the durable main-checkout anchor), not $PWD — pitch writes land there
# regardless of which worktree the session's implementation work occupies.
# Not `exec` — the wrapper must regain control after pi exits to run
# postflight; it preserves pi's own exit code on a non-zero/aborted session.
source "$CODEGEN_DIR/harnesses/shared/pitch-postflight.sh"
run_pitch_postflight experiment "$CODEGEN_PITCH_ROOT" -- pi \
    "${NON_INTERACTIVE_FLAGS[@]+"${NON_INTERACTIVE_FLAGS[@]}"}" \
    --model "$ROLE_MODEL" \
    --thinking "$ROLE_EFFORT" \
    --tools read,grep,find,ls,edit,write,bash \
    --no-extensions \
    --extension "$EXTENSIONS_DIR/askuserquestion" \
    --extension "$EXTENSIONS_DIR/subagents" \
    --extension "$EXTENSIONS_DIR/web-utils" \
    --system-prompt "$ROLE_SYSTEM_PROMPT" \
    "$@"
