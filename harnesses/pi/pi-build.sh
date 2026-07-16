#!/usr/bin/env bash
# Pi build launcher — analogous to claude-build.sh.
#
# Resolves the pitch/prompt argument, then delegates to codegen-build, which
# always drives the deterministic Elixir orchestration loop.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
BUILD_BIN="${OCG_CODEGEN_DIR:+$OCG_CODEGEN_DIR/codegen-build}"
BUILD_BIN="${BUILD_BIN:-$SCRIPT_DIR/codegen-build}"

# --queue: drain codegen/pitches/ready/ one pitch at a time instead of
# building a single pitch, via the Elixir multi-pitch drain
# (mix codegen.loop.queue). Takes no slug arguments — any other arg
# alongside --queue is a usage error.
_has_queue_flag=0
for _qarg in "$@"; do
    if [[ "$_qarg" == "--queue" ]]; then
        _has_queue_flag=1
    fi
done
if [[ "$_has_queue_flag" -eq 1 ]]; then
    for _qarg in "$@"; do
        if [[ "$_qarg" != "--queue" ]]; then
            printf 'pi-build: --queue takes no slug arguments — got: %s\n' "$_qarg" >&2
            exit 1
        fi
    done
    _QUEUE_CWD="$PWD"
    # Portable derivation (matches claude-shape.sh/claude-debug.sh): prefer the
    # override, then the harnesses symlink (installed-flat layout, where this
    # script is copied to ~/.local/bin and SCRIPT_DIR/../.. no longer lands on
    # the repo root), then the in-repo-checkout fallback.
    if [[ -n "${OCG_CODEGEN_DIR:-}" ]]; then
        CODEGEN_DIR="$OCG_CODEGEN_DIR"
    elif [[ -L "$SCRIPT_DIR/harnesses" || -d "$SCRIPT_DIR/harnesses" ]]; then
        CODEGEN_DIR="$(cd -P "$SCRIPT_DIR/harnesses" && cd .. && pwd)"
    else
        CODEGEN_DIR="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
    fi
    if [[ ! -d "$CODEGEN_DIR/test_harness" ]]; then
        printf 'pi-build: test_harness/ not found at %s — set OCG_CODEGEN_DIR to the codegen repo root\n' "$CODEGEN_DIR" >&2
        exit 2
    fi
    cd "$CODEGEN_DIR/test_harness"
    exec mix codegen.loop.queue --harness=pi --stack="${STACK:-phoenix}" --cwd="$_QUEUE_CWD"
fi

# Normalise launch cwd to the nearest legal pitch root so the basename
# resolver, the mention, and the cwd inherited by codegen-build/dispatch
# all key off a dir whose ./codegen/pitches/ready is the intended target.
# A nested $PWD (e.g. inside codegen/pitches) otherwise mis-resolves and the
# basename silently falls through to the literal-prompt branch. codegen-build
# defaults --cwd to $PWD — cd + exec is the only reliable fix (mirrors
# dispatch.sh and claude-shape.sh).
resolve_pitch_root() {
    case "$1" in
    */codegen/pitches/*) printf '%s' "${1%%/codegen/pitches/*}" ;;
    */codegen/pitches) printf '%s' "${1%/codegen/pitches}" ;;
    *) printf '%s' "$1" ;;
    esac
}
PITCH_ROOT="$(resolve_pitch_root "$PWD")"
if [[ "$PITCH_ROOT" != "$PWD" ]]; then
    printf 'pi-build: launched inside codegen/pitches; using repo root %s\n' "$PITCH_ROOT" >&2
    cd "$PITCH_ROOT"
fi

PROMPT_PARTS=()
READY_DIR="$PWD/codegen/pitches/ready"
for arg in "$@"; do
    if [[ "$arg" == */* ]] || [[ "$arg" == *.md ]] || [[ "$arg" == *" "* ]]; then
        PROMPT_PARTS+=("$arg")
        continue
    fi
    if [[ -f "$READY_DIR/${arg}.md" ]]; then
        PROMPT_PARTS+=("codegen/pitches/ready/${arg}.md")
        continue
    fi
    matches=()
    if [[ -d "$READY_DIR" ]]; then
        while IFS= read -r -d '' f; do
            bn="$(basename "$f" .md)"
            if [[ "$bn" == "${arg}"* ]]; then
                matches+=("$bn")
            fi
        done < <(find "$READY_DIR" -maxdepth 1 -name "*.md" -print0 2>/dev/null)
    fi
    if [[ ${#matches[@]} -eq 1 ]]; then
        PROMPT_PARTS+=("codegen/pitches/ready/${matches[0]}.md")
    elif [[ ${#matches[@]} -gt 1 ]]; then
        printf 'pi-build: ambiguous basename %q; matches:\n' "$arg" >&2
        for m in "${matches[@]+"${matches[@]}"}"; do printf '  %s\n' "$m" >&2; done
        exit 1
    else
        PROMPT_PARTS+=("$arg")
    fi
done

exec "$BUILD_BIN" \
    --harness=pi \
    "${STACK:+--stack=$STACK}" \
    "${PROMPT_PARTS[@]+"${PROMPT_PARTS[@]}"}"
