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
    DEFAULT_MODEL="sonnet"
    PLAN_OUTPUT_FILE="codegen/bird_eye_plans/${FEATURE_NAME}.md"
    echo "✓ Ensured codegen/bird_eye_plans directory exists"
    ;;
"detailed-planning")
    mkdir -p "$TARGET_REPO_PATH/codegen/plans"
    DEFAULT_MODEL="sonnet"
    PLAN_OUTPUT_FILE="codegen/plans/${FEATURE_NAME}.md"
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

# Set up cleanup to remove planning context when session ends
cleanup_planning_context() {
    if [ -f "$PLANNING_SESSION_CONTEXT_FILE" ]; then
        rm "$PLANNING_SESSION_CONTEXT_FILE"
        echo "✓ Cleaned up planning session context"
    fi
}
trap cleanup_planning_context EXIT

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

echo ""
echo "=== Planning Session Ready ==="
echo "Mode: $MODE"
echo "Feature: ${FEATURE_NAME:-"(not specified)"}"
echo "Working Directory: $TARGET_REPO_PATH"
echo "Model: $MODEL"
echo ""

# Start Claude with appropriate model
echo "Starting Claude with $MODEL model..."
echo "Planning context created, Claude will read it automatically."
echo ""

export SHELL=/bin/bash
if command -v claude >/dev/null 2>&1; then
    exec claude --model "$MODEL" "$PLANNING_PROMPT"
else
    echo "⚠️  Claude CLI not found. Please install Claude CLI first and try again."
    exit 1
fi
