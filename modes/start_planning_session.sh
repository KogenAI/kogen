#!/bin/bash

# Core logic for starting planning sessions
# Usage: start_planning_session.sh <mode> [feature_name] [model]

set -e

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODEGEN_DIR="$(dirname "$SCRIPT_DIR")"

# Source utilities
source "$CODEGEN_DIR/utils.sh"
source "$CODEGEN_DIR/config.sh"

MODE="$1"
FEATURE_NAME="$2"
MODEL_OVERRIDE="$3"

# Validate mode
case "$MODE" in
"bird-eye" | "detailed-planning") ;;
*)
    echo "Error: Invalid mode '$MODE'. Valid modes: bird-eye, detailed-planning"
    exit 1
    ;;
esac

# Create planning session context file (unique per session)
TEMPLATE_DIR="$CODEGEN_DIR/templates/planning-sessions/$MODE"
SESSION_ID="$$" # Just use process ID for simplicity
mkdir -p "$TARGET_REPO_PATH/codegen/planning_sessions"
PLANNING_SESSION_CONTEXT_FILE="$TARGET_REPO_PATH/codegen/planning_sessions/PLANNING_SESSION_CONTEXT_${SESSION_ID}.md"

# Add session timestamp
SESSION_TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

# Create directories for outputs and set default model
case "$MODE" in
"bird-eye")
    mkdir -p "$TARGET_REPO_PATH/codegen/bird_eye_plans"
    DEFAULT_MODEL="opus"
    PLAN_OUTPUT_FILE="codegen/bird_eye_plans/${FEATURE_NAME}.md"
    echo "✓ Ensured codegen/bird_eye_plans directory exists"
    ;;
"detailed-planning")
    mkdir -p "$TARGET_REPO_PATH/codegen/plans"
    DEFAULT_MODEL="opus"
    PLAN_OUTPUT_FILE="codegen/plans/${FEATURE_NAME}/"
    echo "✓ Ensured codegen/plans directory exists"
    ;;
esac

# Prepare initial prompt for Claude
PLANNING_PROMPT="This is a planning session. Please read codegen/planning_sessions/PLANNING_SESSION_CONTEXT_${SESSION_ID}.md first to understand your role and constraints, then read codegen/PROJECT_CONTEXT.md to understand the project architecture and patterns. After reading both files, wait for me to describe the feature to plan."

# Create the context file for this session
if [ -f "$TEMPLATE_DIR/SESSION_CONTEXT.md" ]; then
    sed -e "s/{{FEATURE_NAME}}/$FEATURE_NAME/g" \
        -e "s/{{SESSION_TIMESTAMP}}/$SESSION_TIMESTAMP/g" \
        -e "s|{{PLAN_OUTPUT_FILE}}|$PLAN_OUTPUT_FILE|g" \
        "$TEMPLATE_DIR/SESSION_CONTEXT.md" >"$PLANNING_SESSION_CONTEXT_FILE"
    echo "✓ Created planning session context: codegen/planning_sessions/PLANNING_SESSION_CONTEXT_${SESSION_ID}.md"
else
    echo "Error: Template not found: $TEMPLATE_DIR/SESSION_CONTEXT.md"
    exit 1
fi

# Variables for server management
PHOENIX_PID=""
PLAYWRIGHT_PID=""
PHOENIX_PORT="4000"
PLAYWRIGHT_PORT="8900"

# Set up cleanup to remove planning context and stop servers when session ends
cleanup_planning_session() {
    # Clean up planning context
    if [ -f "$PLANNING_SESSION_CONTEXT_FILE" ]; then
        rm "$PLANNING_SESSION_CONTEXT_FILE"
        echo "✓ Cleaned up planning session context"
    fi

    # Stop Phoenix server
    if [ -n "$PHOENIX_PID" ] && kill -0 "$PHOENIX_PID" 2>/dev/null; then
        echo "🛑 Stopping Phoenix server..."
        kill "$PHOENIX_PID" 2>/dev/null || true
        wait "$PHOENIX_PID" 2>/dev/null || true
    fi

    # Stop Playwright server
    if [ -n "$PLAYWRIGHT_PID" ] && kill -0 "$PLAYWRIGHT_PID" 2>/dev/null; then
        echo "🛑 Stopping Playwright MCP server..."
        kill "$PLAYWRIGHT_PID" 2>/dev/null || true
        wait "$PLAYWRIGHT_PID" 2>/dev/null || true
    fi

    # Kill any remaining processes on the ports
    if lsof -ti tcp:$PHOENIX_PORT >/dev/null 2>&1; then
        lsof -ti tcp:$PHOENIX_PORT | xargs kill -9 2>/dev/null || true
    fi
    if lsof -ti tcp:$PLAYWRIGHT_PORT >/dev/null 2>&1; then
        lsof -ti tcp:$PLAYWRIGHT_PORT | xargs kill -9 2>/dev/null || true
    fi
}
trap cleanup_planning_session EXIT

# Use model override if provided, otherwise use default
if [ -n "$MODEL_OVERRIDE" ]; then
    # Validate model override
    case "$MODEL_OVERRIDE" in
    "sonnet" | "opus")
        MODEL="$MODEL_OVERRIDE"
        echo "✓ Using model override: $MODEL"
        ;;
    *)
        echo "Error: Invalid model '$MODEL_OVERRIDE'. Valid models: sonnet, opus"
        exit 1
        ;;
    esac
else
    MODEL="$DEFAULT_MODEL"
fi

# Change to target repository directory
cd "$TARGET_REPO_PATH"

# Check and kill any existing servers on our ports
if lsof -ti tcp:$PHOENIX_PORT >/dev/null 2>&1; then
    echo "🔄 Killing existing process on port $PHOENIX_PORT..."
    lsof -ti tcp:$PHOENIX_PORT | xargs kill -9 2>/dev/null || true
    sleep 1
fi

if lsof -ti tcp:$PLAYWRIGHT_PORT >/dev/null 2>&1; then
    echo "🔄 Killing existing process on port $PLAYWRIGHT_PORT..."
    lsof -ti tcp:$PLAYWRIGHT_PORT | xargs kill -9 2>/dev/null || true
    sleep 1
fi

# Start Phoenix server if mix.exs exists
if [ -f "mix.exs" ]; then
    echo "🚀 Starting Phoenix server on port $PHOENIX_PORT..."
    PORT=$PHOENIX_PORT mix phx.server >/dev/null 2>&1 &
    PHOENIX_PID=$!
    echo "✓ Phoenix server started (PID: $PHOENIX_PID)"
else
    echo "⚠️  No mix.exs found, skipping Phoenix server"
fi

# Start Playwright MCP server
if command -v npx >/dev/null 2>&1; then
    echo "🎭 Starting Playwright MCP server on port $PLAYWRIGHT_PORT..."
    npx --yes @playwright/mcp@latest --port $PLAYWRIGHT_PORT --headless --isolated >/dev/null 2>&1 &
    PLAYWRIGHT_PID=$!
    echo "✓ Playwright MCP server started (PID: $PLAYWRIGHT_PID)"
else
    echo "⚠️  npx not found, skipping Playwright MCP server"
fi

# Give servers a moment to start
if [ -n "$PHOENIX_PID" ] || [ -n "$PLAYWRIGHT_PID" ]; then
    echo "⏳ Waiting for servers to initialize..."
    sleep 3
fi

echo ""
echo "=== Planning Session Ready ==="
echo "Mode: $MODE"
echo "Feature: ${FEATURE_NAME:-"(not specified)"}"
echo "Working Directory: $TARGET_REPO_PATH"
echo "Model: $MODEL"
if [ -n "$PHOENIX_PID" ]; then
    echo "🌐 Phoenix server: http://localhost:$PHOENIX_PORT"
fi
if [ -n "$PLAYWRIGHT_PID" ]; then
    echo "🎭 Playwright MCP: port $PLAYWRIGHT_PORT"
fi
echo ""

# Load AI agent configuration
CONFIG_FILE="$HOME/.ocg/config.json"
if [ -f "$CONFIG_FILE" ]; then
    AI_AGENT=$(jq -r '.default_agent // "claude"' "$CONFIG_FILE")
else
    AI_AGENT="claude"
fi

# Start AI agent with appropriate model
echo "Starting $AI_AGENT with $MODEL model..."
echo "Planning context created, $AI_AGENT will read it automatically."
echo ""

# Create temporary prompt file
PROMPT_FILE=$(mktemp)
trap "rm -f $PROMPT_FILE" EXIT
echo "$PLANNING_PROMPT" >"$PROMPT_FILE"

# Run AI agent
"$CODEGEN_DIR/ai-agents/run-ai.sh" "$AI_AGENT" "$MODEL" "$PROMPT_FILE"
