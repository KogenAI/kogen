#!/bin/zsh

# Get the workspace directory (parent of .vscode)
WORKSPACE_DIR="$(dirname "$(dirname "$0")")"

# Change to workspace directory first
cd "$WORKSPACE_DIR"

# Source the user's zshrc to get the full environment
# This ensures we have the same setup as a regular terminal
if [ -f "$HOME/.zshrc" ]; then
    echo "🔧 Loading shell environment..."
    source "$HOME/.zshrc"
    echo "✅ Shell environment loaded"
fi

# Load environment variables from .env file (after zshrc to override if needed)
if [ -f ".env" ]; then
    echo "📄 Loading workspace environment from .env..."
    set -a
    source ".env"
    set +a
    echo "✅ Workspace environment variables loaded"
fi

# Verify mise is working
if command -v mise >/dev/null 2>&1; then
    echo "✅ Mise is available"
    # Ensure we're in the right directory for mise to work
    mise trust .
    # Force mise to reload the environment for this directory
    eval "$(mise env)"
else
    echo "❌ Mise not found after loading shell environment"
fi

# Verify we have the tools (suppress version checks that might fail)
if command -v elixir >/dev/null 2>&1; then
    # Try to get version, but don't fail if it errors
    ELIXIR_VERSION=$(elixir --short-version 2>/dev/null || echo "detected")
    echo "✅ Elixir: $ELIXIR_VERSION"
else
    echo "❌ Elixir not found - environment may not be properly loaded"
fi

if command -v erl >/dev/null 2>&1; then
    # Try to get version, but don't fail if it errors
    ERL_VERSION=$(erl -noshell -eval 'io:format("~s", [erlang:system_info(otp_release)]), halt().' 2>/dev/null || echo "detected")
    echo "✅ Erlang/OTP: $ERL_VERSION"
else
    echo "❌ Erlang not found"
fi

# Wait for startup signal (both assistants should wait)
WAIT_FILE="$WORKSPACE_DIR/codegen/.ai_wait"
if [ -f "$WAIT_FILE" ]; then
    echo "⏳ Waiting for workspace initialization to complete..."
    while [ -f "$WAIT_FILE" ]; do
        sleep 1
    done
    echo "✅ Workspace ready, starting AI assistant..."
fi

# Simple configuration:
# 1. Get assistant from environment or global config
# 2. Get model from environment or use default

CONFIG_FILE="$HOME/.ocg/config.json"

# Get AI assistant (environment variable takes precedence)
AI_ASSISTANT="${AI_ASSISTANT:-}"
if [ -z "$AI_ASSISTANT" ] && [ -f "$CONFIG_FILE" ]; then
    AI_ASSISTANT=$(jq -r '.default_assistant // "claude"' "$CONFIG_FILE" 2>/dev/null)
fi

# Get model (environment variable takes precedence)
MODEL="${AI_MODEL:-${MODEL:-sonnet}}"

# Check if assistant is configured
if [ -z "$AI_ASSISTANT" ]; then
    echo "❌ No AI assistant configured."
    echo "   Please run: ocg ai-config set default [claude|opencode]"
    exit 1
fi

echo "🤖 Starting $AI_ASSISTANT with model: $MODEL"

# Find the ai-assistants directory
if [ -d "$WORKSPACE_DIR/../../ai-assistants" ]; then
    AI_ASSISTANTS_DIR="$WORKSPACE_DIR/../../ai-assistants"
elif [ -d "$HOME/Areas/Optimum/codegen/ai-assistants" ]; then
    AI_ASSISTANTS_DIR="$HOME/Areas/Optimum/codegen/ai-assistants"
else
    echo "❌ Cannot find ai-assistants directory"
    exit 1
fi

# Set Claude-specific environment variable if needed
if [ "$AI_ASSISTANT" = "claude" ]; then
    export CLAUDE_BASH_MAINTAIN_PROJECT_WORKING_DIR=true
fi

# Create prompt file path
PROMPT_FILE="$WORKSPACE_DIR/codegen/PROMPT.md"

# Verify prompt file exists
if [ ! -f "$PROMPT_FILE" ]; then
    echo "❌ Prompt file not found: $PROMPT_FILE"
    exit 1
fi

# Change to workspace directory
cd "$WORKSPACE_DIR"

# Use the same run-ai.sh script as everyone else
"$AI_ASSISTANTS_DIR/run-ai.sh" "$AI_ASSISTANT" "$MODEL" "$PROMPT_FILE"
