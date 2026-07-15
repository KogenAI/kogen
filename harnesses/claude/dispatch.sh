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

# Extra flags (--max-budget-usd, --fallback-model, etc.) passed through as $@
# Last arg is the PROMPT (only if any positional args were given)
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
    printf '%s\n' mix codegen.loop --harness=claude_code "--stack=$STACK" "--cwd=$CWD" -- "$PROMPT"
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
    bash -c 'cd "$1" && exec mix codegen.loop --harness=claude_code "--stack=$2" "--cwd=$3" -- "$4"' \
    _ "$LOOP_DIR" "$STACK" "$CWD" "$PROMPT" &
child_pid=$!

forward_term() {
    kill -0 "$child_pid" 2>/dev/null && kill -TERM -"$child_pid" 2>/dev/null
}
trap 'forward_term' INT TERM

wait "$child_pid"
exit_code=$?
trap - INT TERM
exit "$exit_code"
