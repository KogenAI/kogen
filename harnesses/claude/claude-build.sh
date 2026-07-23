#!/usr/bin/env bash
# Built-in subagents denied: Plan, general-purpose, statusline-setup always.
# Explore allowed only under CLAUDE_ROLE=debug/shape/ops.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
BUILD_BIN="${OCG_CODEGEN_DIR:+$OCG_CODEGEN_DIR/codegen-build}"
BUILD_BIN="${BUILD_BIN:-$SCRIPT_DIR/codegen-build}"

# --queue: drain codegen/pitches/ready/ one pitch at a time instead of
# building a single pitch, via the Elixir multi-pitch drain
# (mix codegen.loop.queue). Takes no slug arguments except the optional
# --watch flag (see CodegenTestHarness.LoopQueueDrain moduledoc "--watch")
# — any other arg alongside --queue is a usage error.
_has_queue_flag=0
_has_watch_flag=0
for _qarg in "$@"; do
    if [[ "$_qarg" == "--queue" ]]; then
        _has_queue_flag=1
    elif [[ "$_qarg" == "--watch" ]]; then
        _has_watch_flag=1
    fi
done
if [[ "$_has_watch_flag" -eq 1 && "$_has_queue_flag" -eq 0 ]]; then
    printf 'claude-build: --watch requires --queue\n' >&2
    exit 1
fi
if [[ "$_has_queue_flag" -eq 1 ]]; then
    for _qarg in "$@"; do
        if [[ "$_qarg" != "--queue" && "$_qarg" != "--watch" ]]; then
            printf 'claude-build: --queue takes no slug arguments — got: %s\n' "$_qarg" >&2
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
        printf 'claude-build: test_harness/ not found at %s — set OCG_CODEGEN_DIR to the codegen repo root\n' "$CODEGEN_DIR" >&2
        exit 2
    fi
    cd "$CODEGEN_DIR/test_harness"
    # Own build root: the drain is long-lived and must never share a Mix
    # build path with a child it spawns via codegen.loop — a child
    # recompiling engine source would otherwise yank beams out from under
    # the drain's own lazily-loaded modules (UndefinedFunctionError).
    export MIX_BUILD_PATH=_build/drain
    _QUEUE_ARGS=(mix codegen.loop.queue --harness=claude --stack="${STACK:-phoenix}" --cwd="$_QUEUE_CWD")
    if [[ "$_has_watch_flag" -eq 1 ]]; then
        _QUEUE_ARGS+=(--watch)
    fi
    # Job-controlled, non-exec spawn via the shared signal bridge: terminal
    # Ctrl-C must become a group SIGTERM to the BEAM (reaped by
    # BuildSignalHandler), not hit Erlang's uncatchable break handler
    # directly — which an `exec` here would do, by replacing this shell.
    # See harnesses/shared/loop-signal-bridge.sh.
    source "$CODEGEN_DIR/harnesses/shared/loop-signal-bridge.sh"
    # Darwin-only: sleep is the sole re-lock trigger for the login Keychain
    # (no idle-lock by default) — a long --watch session left unattended
    # would otherwise let the box sleep and every subsequent spawn die at
    # $0.00 with a lying "OAuth session expired" error (see
    # CodegenTestHarness.LoopQueueDrain moduledoc "Darwin idle-lock").
    # caffeinate prevents sleep; the drain's own pre-spawn :keychain_fn
    # check is the fail-closed backstop for a box with an idle-lock set
    # despite caffeinate. Linux has no caffeinate and no Keychain.
    # Captured with `||`, never bare: under `set -e`, a bare
    # `run_supervised_loop ...` returning non-zero would ABORT this script
    # at that line — the following `exit "$_queue_rc"` would never run.
    _queue_rc=0
    if [[ "$_has_watch_flag" -eq 1 && "$(uname -s)" == "Darwin" ]] && command -v caffeinate >/dev/null 2>&1; then
        run_supervised_loop caffeinate -dimsu "${_QUEUE_ARGS[@]+"${_QUEUE_ARGS[@]}"}" || _queue_rc=$?
        exit "$_queue_rc"
    fi
    run_supervised_loop "${_QUEUE_ARGS[@]+"${_QUEUE_ARGS[@]}"}" || _queue_rc=$?
    exit "$_queue_rc"
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
        for m in "${matches[@]+"${matches[@]}"}"; do printf '  %s\n' "$m" >&2; done
        exit 1
    else
        # Permissive: no match → pass through as literal prompt token
        PROMPT_PARTS+=("$arg")
    fi
done

exec "$BUILD_BIN" \
    --harness=claude \
    "${STACK:+--stack=$STACK}" \
    "${PROMPT_PARTS[@]+"${PROMPT_PARTS[@]}"}"
