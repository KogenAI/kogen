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

# Wait for startup signal (both agents should wait)
WAIT_FILE="$WORKSPACE_DIR/codegen/.ai_wait"
if [ -f "$WAIT_FILE" ]; then
    echo "⏳ Waiting for workspace initialization to complete..."
    while [ -f "$WAIT_FILE" ]; do
        sleep 1
    done
    echo "✅ Workspace ready, starting AI agent..."
fi

# Simple configuration:
# 1. Get agent from environment or global config
# 2. Get model from environment or use default

CONFIG_FILE="$HOME/.ocg/config.json"

# Get AI agent (environment variable takes precedence)
AI_AGENT="${AI_AGENT:-}"
if [ -z "$AI_AGENT" ] && [ -f "$CONFIG_FILE" ]; then
    AI_AGENT=$(jq -r '.default_agent // "claude"' "$CONFIG_FILE" 2>/dev/null)
fi

# Get model (environment variable takes precedence)
MODEL="${AI_MODEL:-${MODEL:-sonnet}}"

# Check if agent is configured
if [ -z "$AI_AGENT" ]; then
    echo "❌ No AI agent configured."
    echo "   Please run: ocg ai-config set default [claude]"
    exit 1
fi

echo "🤖 Starting $AI_AGENT with model: $MODEL"

# Get OCG directory by resolving the ocg command location
if ! command -v ocg >/dev/null 2>&1; then
    echo "❌ OCG command not found"
    echo "   Please run: make install"
    exit 1
fi

# Resolve OCG installation directory from the ocg command
OCG_SCRIPT=$(which ocg)
OCG_DIR=$(cd "$(dirname "$(readlink -f "$OCG_SCRIPT" 2>/dev/null || realpath "$OCG_SCRIPT" 2>/dev/null || echo "$OCG_SCRIPT")")" && pwd)

# Use OCG ai-agents directory
AI_AGENTS_DIR="$OCG_DIR/ai-agents"

if [ ! -d "$AI_AGENTS_DIR" ]; then
    echo "❌ AI agents directory not found: $AI_AGENTS_DIR"
    exit 1
fi

# Set Claude-specific environment variable if needed
if [ "$AI_AGENT" = "claude" ]; then
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

# Use the same run-ai.sh script for all agents
"$AI_AGENTS_DIR/run-ai.sh" "$AI_AGENT" "$MODEL" "$PROMPT_FILE"
