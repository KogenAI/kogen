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
    "bird-eye"|"detailed-planning")
        ;;
    *)
        echo "Error: Invalid mode '$MODE'. Valid modes: bird-eye, detailed-planning"
        exit 1
        ;;
esac

# Create planning-specific CLAUDE.md in codegen directory
TEMPLATE_DIR="$CODEGEN_DIR/templates/planning-sessions/$MODE"

if [ -f "$TEMPLATE_DIR/CLAUDE.md" ]; then
    sed "s/{{FEATURE_NAME}}/$FEATURE_NAME/g" "$TEMPLATE_DIR/CLAUDE.md" > "$CODEGEN_DIR/CLAUDE.md"
    echo "✓ Created planning CLAUDE.md"
else
    echo "Error: Template not found: $TEMPLATE_DIR/CLAUDE.md"
    exit 1
fi

# Create directories for outputs and set default model
case "$MODE" in
    "bird-eye")
        mkdir -p "$CODEGEN_DIR/bird_view_plans"
        DEFAULT_MODEL="sonnet"
        echo "✓ Ensured bird_view_plans directory exists"
        ;;
    "detailed-planning")
        mkdir -p "$CODEGEN_DIR/plans"
        DEFAULT_MODEL="sonnet"
        echo "✓ Ensured plans directory exists"
        ;;
esac

# Use model override if provided, otherwise use default
if [ -n "$MODEL_OVERRIDE" ]; then
    # Validate model override
    case "$MODEL_OVERRIDE" in
        "sonnet"|"opus")
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

# Change to codegen directory
cd "$CODEGEN_DIR"

echo ""
echo "=== Planning Session Ready ==="
echo "Mode: $MODE"
echo "Feature: ${FEATURE_NAME:-"(not specified)"}"
echo "Working Directory: $CODEGEN_DIR"
echo "Model: $MODEL"
echo ""

# Start Claude with appropriate model
echo "Starting Claude with $MODEL model..."
if command -v claude >/dev/null 2>&1; then
    exec claude --model "$MODEL"
else
    echo "Warning: claude command not found. Please install Claude CLI."
    echo "You can manually start Claude with: claude --model $MODEL"
    exit 1
fi
