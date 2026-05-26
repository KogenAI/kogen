#!/usr/bin/env bash
# harnesses/claude/dispatch.sh — Claude Code harness dispatch for codegen-build.
#
# Called by codegen-build with extra flags + prompt as positional args.
# Reads build-tools.txt (one tool per line) → comma-joins → passes as --tools.
# stdout is byte-transparent (stream-json). STDERR: diagnostics only.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SP_FILE="$SCRIPT_DIR/claude-build-system-prompt.txt"

COMMON_FLAGS=(--dangerously-skip-permissions)
if [[ -f "$SP_FILE" ]]; then
    COMMON_FLAGS+=(--system-prompt "$(cat "$SP_FILE")")
fi

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
    CODEGEN_DIR="${OCG_CODEGEN_DIR:-$HOME/Areas/Optimum/codegen}"
    cfg="$CODEGEN_DIR/templates/generator/config.yaml"
    if [[ -f "$cfg" ]]; then
        [[ -z "$MODEL" ]] && MODEL=$(yq -r ".harness.build.claude.model" "$cfg" 2>/dev/null || echo "")
        [[ -z "$EFFORT" ]] && EFFORT=$(yq -r ".harness.build.claude.effort" "$cfg" 2>/dev/null || echo "")
    fi
fi

MODEL="${MODEL:-haiku}"
EFFORT="${EFFORT:-medium}"

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
MAX_TURNS="${CODEGEN_BUILD_MAX_TURNS:-60}"

# Non-interactive: pass all non-interactive flags. Interactive: omit (claude handles tty detection).
NON_INTERACTIVE_FLAGS=()
if [[ -n "$NON_INTERACTIVE" ]]; then
    NON_INTERACTIVE_FLAGS+=(
        --print
        --verbose
        --output-format stream-json
        --setting-sources project
        --strict-mcp-config
        --no-session-persistence
        --disable-slash-commands
    )
fi

# Change into the target working directory before exec so that:
#   1. claude's cwd (and therefore git's .git lookup) is the isolated app dir
#   2. subagents spawned via Agent() inherit this cwd from the process table
# Using `cd` + `exec` is the only reliable way — claude has no --cwd flag.
if [[ -n "$CWD" ]]; then
    cd "$CWD"
fi

exec env \
    -u CLAUDECODE \
    -u CLAUDE_CODE_SSE_PORT \
    -u CLAUDE_CODE_ENTRYPOINT \
    -u CLAUDE_CODE_SESSION_ID \
    -u CLAUDE_CODE_EXECPATH \
    -u AI_AGENT \
    ENABLE_PROMPT_CACHING_1H=1 \
    MAX_THINKING_TOKENS=0 \
    MCP_CONNECTION_NONBLOCKING=true \
    COMBOBULATE_BUILD_START_TS="$(date +%s)" \
    claude \
    "${NON_INTERACTIVE_FLAGS[@]+"${NON_INTERACTIVE_FLAGS[@]}"}" \
    "${COMMON_FLAGS[@]+"${COMMON_FLAGS[@]}"}" \
    --model "$MODEL" \
    --effort "$EFFORT" \
    --max-turns "$MAX_TURNS" \
    --tools "$TOOLS" \
    "${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"}" \
    ${PROMPT:+-- "$PROMPT"}
