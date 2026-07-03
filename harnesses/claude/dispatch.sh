#!/usr/bin/env bash
# harnesses/claude/dispatch.sh — Claude Code harness dispatch for codegen-build.
#
# Called by codegen-build with extra flags + prompt as positional args.
# Reads build-tools.txt (one tool per line) → comma-joins → passes as --tools.
# stdout is byte-transparent (stream-json). STDERR: diagnostics only.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
CODEGEN_DIR="${OCG_CODEGEN_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd -P)}"
SP_FILE="$SCRIPT_DIR/claude-build-system-prompt.txt"

COMMON_FLAGS=(--dangerously-skip-permissions)
if [[ ! -f "$SP_FILE" ]]; then
    printf 'claude dispatch: system prompt file not found at %s\n' "$SP_FILE" >&2
    exit 2
fi
COMMON_FLAGS+=(--system-prompt "$(cat "$SP_FILE")")

# Read tools list from build-tools.txt (one per line, strip blanks/comments)
TOOLS_FILE="$SCRIPT_DIR/build-tools.txt"
if [[ ! -f "$TOOLS_FILE" ]]; then
    printf 'claude dispatch: build-tools.txt not found at %s\n' "$TOOLS_FILE" >&2
    exit 2
fi
TOOLS=$(grep -v '^#' "$TOOLS_FILE" | grep -v '^[[:space:]]*$' | paste -sd ',' -)

# Consume env vars set by codegen-build
CWD="${CODEGEN_BUILD_CWD:-}"
MODEL="${CODEGEN_BUILD_MODEL:-}"
EFFORT="${CODEGEN_BUILD_EFFORT:-}"

# Fall back to config.yaml values if not set
if [[ -z "$MODEL" || -z "$EFFORT" ]]; then
    cfg="$CODEGEN_DIR/templates/generator/config.yaml"
    if [[ -f "$cfg" ]]; then
        if ! command -v yq >/dev/null 2>&1; then
            printf 'claude dispatch: yq not found on PATH (required to read %s)\n' "$cfg" >&2
            exit 2
        fi
        if [[ -z "$MODEL" ]]; then
            if ! MODEL=$(yq -r ".harness.build.claude.model" "$cfg"); then
                printf 'claude dispatch: failed to parse config.yaml at %s\n' "$cfg" >&2
                exit 2
            fi
        fi
        if [[ -z "$EFFORT" ]]; then
            if ! EFFORT=$(yq -r ".harness.build.claude.effort" "$cfg"); then
                printf 'claude dispatch: failed to parse config.yaml at %s\n' "$cfg" >&2
                exit 2
            fi
        fi
    else
        printf 'claude dispatch: config.yaml not found at %s\n' "$cfg" >&2
        exit 1
    fi
fi

if [[ -z "$MODEL" || "$MODEL" == "null" ]]; then
    printf 'claude dispatch: harness.build.claude.model missing/empty in config.yaml\n' >&2
    exit 1
fi
if [[ -z "$EFFORT" || "$EFFORT" == "null" ]]; then
    printf 'claude dispatch: harness.build.claude.effort missing/empty in config.yaml\n' >&2
    exit 1
fi

# Extra flags (--max-budget-usd, --fallback-model, etc.) passed through as $@
# Last arg is the PROMPT (only if any positional args were given)
if [[ $# -gt 0 ]]; then
    PROMPT="${*: -1}"
    EXTRA_FLAGS=()
    if [[ $# -gt 1 ]]; then
        # All args except last are extra flags
        for ((i = 1; i < $#; i++)); do
            EXTRA_FLAGS+=("${!i}")
        done
    fi
else
    PROMPT=""
    EXTRA_FLAGS=()
fi

NON_INTERACTIVE="${CODEGEN_BUILD_NON_INTERACTIVE:-}"
RESUMABLE="${CODEGEN_BUILD_RESUMABLE:-}"
RESUME_ID="${CODEGEN_BUILD_RESUME_ID:-}"
ELIXIR_ENGINE="${CODEGEN_BUILD_ELIXIR:-}"

# Non-interactive: pass all non-interactive flags. Interactive: omit (claude handles tty detection).
NON_INTERACTIVE_FLAGS=()
RESUME_FLAGS=()
if [[ -n "$NON_INTERACTIVE" ]]; then
    NON_INTERACTIVE_FLAGS+=(
        --print
        --verbose
        --output-format stream-json
        --setting-sources user,project,local
        --strict-mcp-config
        --disable-slash-commands
    )
    # Default headless: persistence OFF (--no-session-persistence). Resumable
    # opt-in: omit it so the session persists and --resume can re-attach.
    if [[ -z "$RESUMABLE" ]]; then
        NON_INTERACTIVE_FLAGS+=(--no-session-persistence)
    elif [[ -n "$RESUME_ID" ]]; then
        # Re-attach to a persisted session by id (never valueless → no interactive pick).
        RESUME_FLAGS+=(--resume "$RESUME_ID")
    fi
fi

# Change into the target working directory before exec so that:
#   1. claude's cwd (and therefore git's .git lookup) is the isolated app dir
#   2. subagents spawned via Agent() inherit this cwd from the process table
# Using `cd` + `exec` is the only reliable way — claude has no --cwd flag.
if [[ -n "$CWD" ]]; then
    cd "$CWD"
fi

# Build mode (--elixir, no --resume): the deterministic Elixir
# orchestration loop drives the whole cycle (planner→developer→gate→
# reviewer→curator→committer) via per-role codegen-call invocations,
# instead of a single self-orchestrating claude session. Interactive and
# resumable sessions are untouched — only the one-shot build path uses
# the loop. Engine selected by --elixir; coexists with legacy (default when
# --elixir absent).
#
# PATH: inherit ambient PATH as-is (no mise-shims prepend) — that prepend
# is claude-binary-specific (below) and would shadow a test's stubbed
# `mix` on PATH. `mix` itself must resolve through normal PATH resolution.
if [[ -n "$ELIXIR_ENGINE" && -z "$RESUME_ID" ]]; then
    printf 'claude dispatch: engine=elixir\n' >&2
    STACK="${CODEGEN_BUILD_STACK:-phoenix}"
    LOOP_DIR="$CODEGEN_DIR/test_harness"

    if [[ ! -d "$LOOP_DIR" ]]; then
        printf 'claude dispatch: orchestration loop dir not found at %s\n' "$LOOP_DIR" >&2
        exit 2
    fi

    exec env \
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
        _ "$LOOP_DIR" "$STACK" "$CWD" "$PROMPT"
fi

printf 'claude dispatch: engine=legacy\n' >&2

GATE_PATH="$PATH"
if [[ -d "$HOME/.local/share/mise/shims" ]]; then
    GATE_PATH="$HOME/.local/share/mise/shims:$PATH"
fi

exec env \
    -u ANTHROPIC_API_KEY \
    -u CLAUDECODE \
    -u CLAUDE_CODE_SSE_PORT \
    -u OPENAI_API_KEY \
    -u CLAUDE_CODE_ENTRYPOINT \
    -u CLAUDE_CODE_SESSION_ID \
    -u CLAUDE_CODE_EXECPATH \
    -u AI_AGENT \
    CODEGEN_DIR="$CODEGEN_DIR" \
    PATH="$GATE_PATH" \
    ENABLE_PROMPT_CACHING_1H=1 \
    MAX_THINKING_TOKENS=0 \
    MCP_CONNECTION_NONBLOCKING=true \
    CODEGEN_BUILD_START_TS="$(date +%s)" \
    CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1 \
    claude \
    "${NON_INTERACTIVE_FLAGS[@]+"${NON_INTERACTIVE_FLAGS[@]}"}" \
    "${RESUME_FLAGS[@]+"${RESUME_FLAGS[@]}"}" \
    "${COMMON_FLAGS[@]+"${COMMON_FLAGS[@]}"}" \
    --model "$MODEL" \
    --effort "$EFFORT" \
    --tools "$TOOLS" \
    "${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"}" \
    ${PROMPT:+-- "$PROMPT"}
