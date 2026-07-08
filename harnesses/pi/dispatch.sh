#!/usr/bin/env bash
# harnesses/pi/dispatch.sh — Pi harness dispatch for codegen-build.
#
# Called by codegen-build with extra flags + prompt as positional args.
# stdout is byte-transparent (JSONL from the loop). STDERR: diagnostics only.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
CODEGEN_DIR="${OCG_CODEGEN_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd -P)}"

# Preflight: every role every cycle depends on `codegen-log` succeeding to
# open/write its session-log section. Assert it is present + runnable BEFORE
# any role spawns — a broken/missing install must fail loud and early here,
# never surface mid-cycle as a bare "command not found" after subagents have
# already produced work.
if ! codegen-log --version >/dev/null 2>&1; then
    printf 'pi dispatch: codegen-log unresolvable — run `make install` in codegen\n' >&2
    exit 2
fi

# Extra flags and prompt: last positional arg is PROMPT (only if any positional args given)
if [[ $# -gt 0 ]]; then
    PROMPT="${*: -1}"
else
    PROMPT=""
fi

# Consume CWD env var set by codegen-build
CWD="${CODEGEN_BUILD_CWD:-}"
if [[ -n "$CWD" ]]; then
    cd "$CWD"
fi

# The deterministic Elixir orchestration loop is the sole engine: it drives
# the whole cycle (planner/developer-first per stack → gate → reviewer →
# curator → committer) via per-role codegen-call invocations.
STACK="${CODEGEN_BUILD_STACK:-}"
if [[ -z "$STACK" ]]; then
    printf 'pi dispatch: CODEGEN_BUILD_STACK is required but empty/unset\n' >&2
    exit 2
fi
LOOP_DIR="$CODEGEN_DIR/test_harness"

if [[ ! -d "$LOOP_DIR" ]]; then
    printf 'pi dispatch: orchestration loop dir not found at %s\n' "$LOOP_DIR" >&2
    exit 2
fi

exec env \
    -u OPENAI_API_KEY \
    -u ANTHROPIC_API_KEY \
    -u CURSOR_API_KEY \
    bash -c 'cd "$1" && exec mix codegen.loop --harness=pi "--stack=$2" "--cwd=$3" -- "$4"' \
    _ "$LOOP_DIR" "$STACK" "$CWD" "$PROMPT"
