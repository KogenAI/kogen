#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"
source "$SCRIPT_DIR/utils.sh"

REPO_ROOT="$TARGET_REPO_PATH"
CONTEXT_FILE="$REPO_ROOT/codegen/PROJECT_CONTEXT.md"

if [ ! -f "$CONTEXT_FILE" ]; then
    echo "❌ Error: PROJECT_CONTEXT.md not found"
    echo "Please run '$OCG_CMD setup' first to initialize the project context"
    exit 1
fi

# Get current file size
ORIGINAL_SIZE=$(wc -l <"$CONTEXT_FILE" | tr -d ' ')

# Determine target size based on current size
TARGET_MIN=300
TARGET_MAX=400
if [ "$ORIGINAL_SIZE" -gt 2000 ]; then
    TARGET_MAX=500 # Allow up to 500 for very large codebases
fi

# Check if file is already in optimal range
if [ "$ORIGINAL_SIZE" -ge "$TARGET_MIN" ] && [ "$ORIGINAL_SIZE" -le "$TARGET_MAX" ]; then
    echo "✅ PROJECT_CONTEXT.md is already in the optimal range ($ORIGINAL_SIZE lines)"
    echo "   Target range: $TARGET_MIN-$TARGET_MAX lines"
    echo ""
    echo "Continue anyway? [y/N]"
    read -r confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        echo "❌ Operation cancelled"
        exit 1
    fi
elif [ "$ORIGINAL_SIZE" -lt "$TARGET_MIN" ]; then
    echo "⚠️  Warning: PROJECT_CONTEXT.md is already quite small ($ORIGINAL_SIZE lines)"
    echo "   Target range: $TARGET_MIN-$TARGET_MAX lines"
    echo "   Consolidation might remove important information."
    echo ""
    echo "Continue anyway? [y/N]"
    read -r confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        echo "❌ Operation cancelled"
        exit 1
    fi
fi

echo "🔄 Consolidating project context..."
echo "📁 Project: $REPO_ROOT"
echo "📄 Context file: $CONTEXT_FILE"
echo "📏 Current size: $ORIGINAL_SIZE lines"
echo "🎯 Target range: $TARGET_MIN-$TARGET_MAX lines"
echo ""

# Define the prompt for context consolidation
CONSOLIDATE_PROMPT="# Consolidate PROJECT_CONTEXT.md

I need you to optimize the PROJECT_CONTEXT.md file to fit within $TARGET_MIN-$TARGET_MAX lines while preserving ALL critical knowledge.

Current file size: $ORIGINAL_SIZE lines
Target size: $TARGET_MIN-$TARGET_MAX lines

## Context Window Consideration

This PROJECT_CONTEXT.md is one of 3 files loaded in each development session:
1. PROJECT_CONTEXT.md (main project knowledge) - Target: $TARGET_MIN-$TARGET_MAX lines
2. Feature context (current feature) - ~200-300 lines
3. Plan file (feature plan) - ~50-100 lines

We need to keep the total under ~800 lines to leave room for actual development work.

## Your Task

Please consolidate PROJECT_CONTEXT.md to meet the target size by:

1. **Remove true redundancies** - If the same information appears multiple times, keep it only once
2. **Preserve ALL module names** - Keep full module names (e.g., TenantManagementLive.PropertyManagement.PropertyTree) for Tidewave/MCP
3. **Consolidate feature learnings** - Integrate insights into relevant sections with brief attribution
4. **Condense verbose sections** - Make descriptions concise but complete
5. **Keep critical details** - Function names, patterns, database schemas, API endpoints

## Consolidation Strategy

Based on the current size ($ORIGINAL_SIZE lines), apply these strategies:
"

# Add dynamic strategy based on file size
if [ "$ORIGINAL_SIZE" -gt 1000 ]; then
    CONSOLIDATE_PROMPT="$CONSOLIDATE_PROMPT
- **Aggressive consolidation needed** - Remove all redundancies, merge similar sections
- **Summarize feature implementations** - Keep only key learnings, not full narratives
- **Condense module descriptions** - One line per module unless it's complex
- **Combine related patterns** - Group similar patterns together"
elif [ "$ORIGINAL_SIZE" -gt 600 ]; then
    CONSOLIDATE_PROMPT="$CONSOLIDATE_PROMPT
- **Moderate consolidation** - Focus on removing duplicates and verbose descriptions
- **Streamline feature section** - Keep important learnings but remove implementation details
- **Tighten module descriptions** - 2-3 lines max per module"
else
    CONSOLIDATE_PROMPT="$CONSOLIDATE_PROMPT
- **Light consolidation** - Only remove obvious duplicates
- **Keep most content** - Focus on better organization rather than removal
- **Preserve detail** - The file is already reasonably sized"
fi

CONSOLIDATE_PROMPT="$CONSOLIDATE_PROMPT

## Preservation Requirements

MUST preserve:
- Full module names and paths (for Tidewave/MCP compatibility)
- Database schemas and relationships
- API endpoints and LiveView routes
- Critical patterns and pitfalls
- Testing approaches that worked

CAN condense:
- Verbose feature descriptions
- Repeated explanations of the same concept
- Implementation narratives (keep only learnings)
- Overly detailed module descriptions

## Expected Structure

Optimize for ~$TARGET_MIN-$TARGET_MAX lines with:
- **Project Overview** (5-10 lines) - Mission and core architecture
- **Module Directory** (100-150 lines) - Full names, concise descriptions
- **Tech Stack & Patterns** (50-75 lines) - Key patterns with examples
- **Development Guidelines** (50-75 lines) - Do's, don'ts, and pitfalls
- **Feature Implementations** (50-100 lines) - Key learnings only

Remember: This file needs to fit efficiently in Claude's context alongside:
- Feature context (CONTEXT.md): 200-300 lines of active work and learnings
- Plan file (PLAN.md): 50-100 lines of implementation steps

Start by reading the current PROJECT_CONTEXT.md and create an optimized version that fits the target range."

echo "🎯 Context consolidation ready!"
echo "🤖 Starting Claude Code with Opus model for thorough analysis..."

cd "$REPO_ROOT"

export SHELL=/bin/bash
if command -v claude >/dev/null 2>&1; then
    exec claude --model opus "$CONSOLIDATE_PROMPT"
else
    echo "⚠️  Claude CLI not found. Please install Claude CLI first and try again."
    exit 1
fi
