#!/usr/bin/env bash
# harnesses/claude/dispatch.sh — Claude Code harness dispatch for codegen-build.
#
# Called by codegen-build with extra flags + prompt as positional args.
# stdout is byte-transparent (stream-json from the loop). STDERR: diagnostics only.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
CODEGEN_DIR="${OCG_CODEGEN_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd -P)}"

# Preflight: every role every cycle depends on `codegen-log` succeeding to
# open/write its session-log section. Assert it is present + runnable BEFORE
# any role spawns — a broken/missing install must fail loud and early here,
# never surface mid-cycle as a bare "command not found" after subagents have
# already produced work.
if ! codegen-log --version >/dev/null 2>&1; then
    printf 'claude dispatch: codegen-log unresolvable — run `make install` in codegen\n' >&2
    exit 2
fi

# Consume env vars set by codegen-build
CWD="${CODEGEN_BUILD_CWD:-}"
PRINT_ARGV="${CODEGEN_BUILD_PRINT_ARGV:-}"
FALLBACK_MODEL="${CODEGEN_BUILD_FALLBACK_MODEL:-}"
MAX_BUDGET_USD="${CODEGEN_BUILD_MAX_BUDGET_USD:-}"
EFFORT="${CODEGEN_BUILD_EFFORT:-}"

# Extra flags (--max-budget-usd, etc.) are NOT forwarded via $@ — this script
# never splats codegen-build's positionals onward. Any such flag that reaches
# the loop is threaded through by name (env var or explicit argv entry),
# never blind-passed. --fallback-model is threaded via CODEGEN_BUILD_FALLBACK_MODEL
# (above) into an explicit `--fallback-model=<m>` argv entry to `mix
# codegen.loop` below. --max-budget-usd is threaded the same way via
# CODEGEN_BUILD_MAX_BUDGET_USD into an explicit `--max-budget-usd=<n>` argv
# entry. --effort is threaded the same way via CODEGEN_BUILD_EFFORT into an
# explicit `--effort=<e>` argv entry. Only the last positional is read below,
# and only as the PROMPT (only if any positional args were given).
if [[ $# -gt 0 ]]; then
    PROMPT="${*: -1}"
else
    PROMPT=""
fi

# Change into the target working directory before exec so that:
#   1. the loop's cwd (and therefore git's .git lookup) is the isolated app dir
#   2. subagents spawned via Agent() inherit this cwd from the process table
if [[ -n "$CWD" ]]; then
    cd "$CWD"
fi

# The deterministic Elixir orchestration loop is the sole engine: it drives
# the whole cycle (planner→developer→gate→reviewer→curator→committer) via
# per-role codegen-call invocations.
STACK="${CODEGEN_BUILD_STACK:-}"
if [[ -z "$STACK" ]]; then
    printf 'claude dispatch: CODEGEN_BUILD_STACK is required but empty/unset\n' >&2
    exit 2
fi
LOOP_DIR="$CODEGEN_DIR/test_harness"

if [[ ! -d "$LOOP_DIR" ]]; then
    printf 'claude dispatch: orchestration loop dir not found at %s\n' "$LOOP_DIR" >&2
    exit 2
fi

# --print-argv dry-run: print the would-be loop argv, one arg per line, exit
# 0. Never execs the loop -- no spend, no mutation.
if [[ -n "$PRINT_ARGV" ]]; then
    _argv=(mix codegen.loop --harness=claude_code "--stack=$STACK" "--cwd=$CWD")
    if [[ -n "$FALLBACK_MODEL" ]]; then
        _argv+=("--fallback-model=$FALLBACK_MODEL")
    fi
    if [[ -n "$MAX_BUDGET_USD" ]]; then
        _argv+=("--max-budget-usd=$MAX_BUDGET_USD")
    fi
    if [[ -n "$EFFORT" ]]; then
        _argv+=("--effort=$EFFORT")
    fi
    _argv+=(-- "$PROMPT")
    printf '%s\n' "${_argv[@]}"
    exit 0
fi

# Job-controlled, non-exec spawn: SIGINT is uncatchable inside the BEAM
# (`:os.set_signal/2` excludes :sigint on every OTP release — see
# test_harness/lib/codegen_test_harness/build_signal_handler.ex moduledoc),
# so this shell must stay alive after spawning the loop, trap INT/TERM
# itself, and forward SIGTERM (which IS catchable) to the child's process
# group. `set -m` puts the child in its own process group with
# child_pid == PGID, so `kill -TERM -$child_pid` reaches the loop AND every
# descendant it spawns. Mirrors the shipped build-queue.sh trap pattern
# (codegen/pitches/shipped/build-queue-process-supervision.md).
#
# Snapshot .active BEFORE the spawn: the exit-record write (below) needs to
# tell "the loop inited its own log for this run" apart from "the loop died
# before it ever inited one" — comparing .active before/after is how.
_active_sentinel="$CWD/codegen/logging/.active"
_active_before=""
[[ -f "$_active_sentinel" ]] && _active_before="$(cat "$_active_sentinel" 2>/dev/null || true)"

# Bounded stderr capture: the child's stderr is teed to a temp file from
# INSIDE the inner bash -c wrapper, so a clean exit's raise stacktrace survives
# even though nothing else durable does. Use a named FIFO rather than process
# substitution: restricted runners can deny the `/dev/fd/*` open that
# `2> >(tee ...)` requires before the loop even starts. Stdout stays
# byte-transparent, and the loop's exit status is preserved explicitly.
_stderr_tail_file="$(mktemp)"
trap 'rm -f "$_stderr_tail_file"' EXIT

set -m
env \
    -u ANTHROPIC_API_KEY \
    -u CLAUDECODE \
    -u CLAUDE_CODE_SSE_PORT \
    -u OPENAI_API_KEY \
    -u CLAUDE_CODE_ENTRYPOINT \
    -u CLAUDE_CODE_SESSION_ID \
    -u CLAUDE_CODE_EXECPATH \
    -u AI_AGENT \
    CODEGEN_DIR="$CODEGEN_DIR" \
    MIX_BUILD_PATH=_build/loop \
    bash -c 'cd "$1" && _loop_argv=(mix codegen.loop --harness=claude_code "--stack=$2" "--cwd=$3")
        if [[ -n "$5" ]]; then _loop_argv+=("--fallback-model=$5"); fi
        if [[ -n "$6" ]]; then _loop_argv+=("--max-budget-usd=$6"); fi
        if [[ -n "$8" ]]; then _loop_argv+=("--effort=$8"); fi
        _loop_argv+=(-- "$4")
        _stderr_fifo="$(mktemp "${TMPDIR:-/tmp}/codegen-stderr.XXXXXX")"
        rm -f "$_stderr_fifo"
        mkfifo "$_stderr_fifo"
        trap '\''rm -f "$_stderr_fifo"'\'' EXIT
        tee "$7" <"$_stderr_fifo" >&2 &
        _tee_pid=$!
        "${_loop_argv[@]}" 2>"$_stderr_fifo"
        _status=$?
        wait "$_tee_pid" || true
        exit "$_status"' \
    _ "$LOOP_DIR" "$STACK" "$CWD" "$PROMPT" "$FALLBACK_MODEL" "$MAX_BUDGET_USD" "$_stderr_tail_file" "$EFFORT" </dev/null &
child_pid=$!

forward_term() {
    kill -0 "$child_pid" 2>/dev/null && kill -TERM -"$child_pid" 2>/dev/null
}
trap 'forward_term' INT TERM

# The child's wait status must be captured with `||`, never a bare `wait`:
# under `set -e`, a bare `wait "$child_pid"` returning non-zero ABORTS this
# script at that line — exit_code=$? and everything after it would never
# run on exactly the death classes this record exists to catch.
exit_code=0
wait "$child_pid" || exit_code=$?
trap - INT TERM

# Decode signal deaths (128+N convention — see
# test_harness/lib/codegen_test_harness/build_signal_handler.ex moduledoc,
# which encodes the same convention for its own halt codes).
_signal=""
if [[ "$exit_code" -gt 128 ]]; then
    _signal=$((exit_code - 128))
fi
_stderr_tail=""
if [[ -s "$_stderr_tail_file" ]]; then
    _stderr_tail="$(tail -c 8192 "$_stderr_tail_file" 2>/dev/null || true)"
fi

# Write the exit record. Fail-loud-non-blocking: a codegen-log failure here
# prints to stderr and never changes exit_code (log-write-not-a-gate).
_active_after=""
[[ -f "$_active_sentinel" ]] && _active_after="$(cat "$_active_sentinel" 2>/dev/null || true)"
if [[ -n "$_active_after" && "$_active_after" != "$_active_before" ]]; then
    _exit_args=(exit --status "$exit_code")
    [[ -n "$_signal" ]] && _exit_args+=(--signal "$_signal")
    [[ -n "$_stderr_tail" ]] && _exit_args+=(--stderr-tail "$_stderr_tail")
    CODEGEN_LOG_PATH="$_active_after" "$CODEGEN_DIR/codegen-log" "${_exit_args[@]}" >/dev/null 2>&1 ||
        printf 'claude dispatch: codegen-log exit record failed (non-fatal)\n' >&2
else
    printf 'claude dispatch: loop exited %s before a cycle log existed — not recorded\n' "$exit_code" >&2
fi

exit "$exit_code"
