#!/bin/bash
# Centralized AI agent runner
# Usage: run-ai.sh <assistant> <model> <prompt_file>

set -e

AGENT="${1:-}"
MODEL="${2:-}"
PROMPT_FILE="${3:-}"

# Validate arguments
if [ -z "$AGENT" ] || [ -z "$MODEL" ] || [ -z "$PROMPT_FILE" ]; then
    echo "❌ Usage: run-ai.sh <assistant> <model> <prompt_file>"
    exit 1
fi

if [ ! -f "$PROMPT_FILE" ]; then
    echo "❌ Prompt file not found: $PROMPT_FILE"
    exit 1
fi

# Get the directory of this script
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Source the model mapper
source "$SCRIPT_DIR/model-mapper.sh"

# Set consistent shell environment
export SHELL=/bin/bash

# Read prompt content once
PROMPT_CONTENT=$(<"$PROMPT_FILE")

case "$AGENT" in
claude)
    if ! command -v claude >/dev/null 2>&1; then
        echo "⚠️  Claude CLI not found. Please install Claude CLI first and try again."
        exit 1
    fi

    # Check if we're running in non-interactive mode (for setup)
    if [ -n "$OCG_NON_INTERACTIVE" ]; then
        # Non-interactive mode - use --print to run without terminal
        claude --dangerously-skip-permissions --model "$MODEL" --print "$PROMPT_CONTENT"
    else
        # Interactive mode - exec to replace shell
        exec claude --dangerously-skip-permissions --model "$MODEL" "$PROMPT_CONTENT"
    fi
    ;;
codex)
    if ! command -v codex >/dev/null 2>&1; then
        echo "⚠️  Codex CLI not found. Please install Codex CLI first and try again."
        exit 1
    fi
    # Map model name for Codex
    CODEX_MODEL=$(map_model "$MODEL" "codex")

    # Use interactive mode
    exec codex --model "$CODEX_MODEL" --prompt "$PROMPT_CONTENT"
    ;;
*)
    echo "❌ Unknown AI agent: $AGENT"
    exit 1
    ;;
esac
