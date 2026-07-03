#!/usr/bin/env bash
# Built-in subagents denied: Plan, general-purpose, statusline-setup always.
# Explore allowed only under CLAUDE_ROLE=debug/shape/ops.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
BUILD_BIN="${OCG_CODEGEN_DIR:+$OCG_CODEGEN_DIR/codegen-build}"
BUILD_BIN="${BUILD_BIN:-$SCRIPT_DIR/codegen-build}"

# --elixir: engine selector, passed through to codegen-build. Strip it out
# BEFORE the basename resolver loop below (it starts with -- so the resolver
# would otherwise drop it into the literal-prompt branch and pollute
# PROMPT_PARTS); re-add explicitly on the final exec.
_ELIXIR_FLAG=0
_FILTERED_ARGS=()
for _farg in "$@"; do
    if [[ "$_farg" == "--elixir" ]]; then
        _ELIXIR_FLAG=1
    else
        _FILTERED_ARGS+=("$_farg")
    fi
done
set -- "${_FILTERED_ARGS[@]+"${_FILTERED_ARGS[@]}"}"

# --queue: drain codegen/pitches/ready/ via the Elixir multi-pitch drain
# (mix codegen.loop.queue) instead of building a single pitch. Takes no
# slug arguments (--elixir is allowed alongside --queue, already stripped
# above) — any other arg alongside --queue is a usage error.
_has_queue_flag=0
for _qarg in "$@"; do
    if [[ "$_qarg" == "--queue" ]]; then
        _has_queue_flag=1
    fi
done
if [[ "$_has_queue_flag" -eq 1 ]]; then
    for _qarg in "$@"; do
        if [[ "$_qarg" != "--queue" ]]; then
            printf 'claude-build: --queue takes no slug arguments — got: %s\n' "$_qarg" >&2
            exit 1
        fi
    done
    _QUEUE_CWD="$PWD"
    CODEGEN_DIR="${OCG_CODEGEN_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd -P)}"
    if [[ ! -d "$CODEGEN_DIR/test_harness" ]]; then
        printf 'claude-build: test_harness/ not found at %s — set OCG_CODEGEN_DIR to the codegen repo root\n' "$CODEGEN_DIR" >&2
        exit 2
    fi
    cd "$CODEGEN_DIR/test_harness"
    exec mix codegen.loop.queue --harness=claude --stack="${STACK:-phoenix}" --cwd="$_QUEUE_CWD"
fi

# Normalise launch cwd to the nearest legal pitch root so the basename
# resolver, the @-mention, and the cwd inherited by codegen-build/dispatch
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
    printf 'claude-build: launched inside codegen/pitches; using repo root %s\n' "$PITCH_ROOT" >&2
    cd "$PITCH_ROOT"
fi

# Basename resolver (permissive) against $PWD/codegen/pitches/ready/
# 1. Contains / or ends in .md or contains space → pass through unchanged.
# 2. codegen/pitches/ready/<arg>.md exists → @-mention it.
# 3. Exactly one prefix match → @-mention it.
# 4. Multiple prefix matches → error + list + exit 1.
# 5. No match → pass through unchanged (preserves Elixir runner free-form-prompt path).
PROMPT_PARTS=()
READY_DIR="$PWD/codegen/pitches/ready"
for arg in "$@"; do
    if [[ "$arg" == */* ]] || [[ "$arg" == *.md ]] || [[ "$arg" == *" "* ]]; then
        PROMPT_PARTS+=("$arg")
        continue
    fi
    if [[ -f "$READY_DIR/${arg}.md" ]]; then
        PROMPT_PARTS+=("@codegen/pitches/ready/${arg}.md")
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
        PROMPT_PARTS+=("@codegen/pitches/ready/${matches[0]}.md")
    elif [[ ${#matches[@]} -gt 1 ]]; then
        printf 'claude-build: ambiguous basename %q; matches:\n' "$arg" >&2
        for m in "${matches[@]}"; do printf '  %s\n' "$m" >&2; done
        exit 1
    else
        # Permissive: no match → pass through as literal prompt token
        PROMPT_PARTS+=("$arg")
    fi
done

ELIXIR_FLAGS=()
if [[ "$_ELIXIR_FLAG" -eq 1 ]]; then
    ELIXIR_FLAGS+=(--elixir)
fi

exec "$BUILD_BIN" \
    --harness=claude \
    --stack="${STACK:-phoenix}" \
    "${ELIXIR_FLAGS[@]+"${ELIXIR_FLAGS[@]}"}" \
    "${PROMPT_PARTS[@]+"${PROMPT_PARTS[@]}"}"
