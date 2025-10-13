#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"
source "$SCRIPT_DIR/utils.sh"

REPO_ROOT="$TARGET_REPO_PATH"
CONTEXT_FILE="$REPO_ROOT/codegen/PROJECT_CONTEXT.md"
RECIPES_DIR="$REPO_ROOT/codegen/recipes"
RULES_DIR="$REPO_ROOT/codegen/rules"

if [ ! -f "$CONTEXT_FILE" ]; then
    echo "❌ Error: PROJECT_CONTEXT.md not found"
    echo "Please run '$OCG_CMD setup' first to initialize the project context"
    exit 1
fi

# Get current file size
ORIGINAL_SIZE=$(wc -l <"$CONTEXT_FILE" | tr -d ' ')

# Determine target size based on current size
# Updated based on BemedaPersonal consolidation learnings:
# - 165-250 lines is optimal for clarity while leaving room for context
# - Features section often better integrated than listed separately
TARGET_MIN=150
TARGET_MAX=250
if [ "$ORIGINAL_SIZE" -gt 2000 ]; then
    TARGET_MIN=200
    TARGET_MAX=300 # Even large codebases can be concise
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

if [ -d "$RECIPES_DIR" ] && [ "$(ls -A "$RECIPES_DIR" 2>/dev/null)" ]; then
    RECIPES_COUNT=$(find "$RECIPES_DIR" -name "*.md" | wc -l | tr -d ' ')
    echo "📚 Recipes found: $RECIPES_COUNT files in $RECIPES_DIR"
fi

if [ -e "$RULES_DIR" ] && [ "$(ls -A "$RULES_DIR" 2>/dev/null)" ]; then
    RULES_COUNT=$(find -L "$RULES_DIR" -name "*.md" | wc -l | tr -d ' ')
    echo "📋 Rules found: $RULES_COUNT files in ./codegen/rules/"
fi

echo ""

# Define the prompt for context consolidation
CONSOLIDATE_PROMPT="# Consolidate PROJECT_CONTEXT.md and Context Knowledge

I need you to optimize the PROJECT_CONTEXT.md file to fit within $TARGET_MIN-$TARGET_MAX lines while preserving ALL critical knowledge.

Also review ./codegen/recipes/ and ./codegen/rules/ directories for any overlapping content that could be consolidated.

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
3. **Remove or integrate feature sections** - Changelog-style feature lists often add no value; integrate learnings into relevant sections instead
4. **Expand cryptic one-liners** - Replace terse descriptions like API to sub-modules with clear explanations
5. **Keep critical details** - Function names, patterns, database schemas, API endpoints
6. **Aim for clarity over extreme brevity** - ~250 lines of clear content is better than 150 cryptic lines

## Rule Consolidation Guidelines

When consolidating ./codegen/rules/ directory:

1. **Merge overlapping rules**:
   - Component testing rules → Add 2 lines to phoenix.md
   - I18n commands → Move to PROJECT_CONTEXT.md if small
   - Regression testing → Merge into elixir-ci.md
   - UI/Frontend rules → Combine into single ui-implementation.md

2. **Delete overly specific rules**:
   - Animation-specific testing (too narrow)
   - One-off implementation patterns
   - Rules that duplicate PROJECT_CONTEXT.md content

3. **Target structure** (~10-12 files max):
   - Core language/framework rules (phoenix, elixir-*)
   - UI implementation (combined figma + frontend)
   - Testing & quality (elixir-ci with all testing)
   - Workflow rules (planning, git, workflow)
   - Specialized tools (wallaby, browser-state-documentation)

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

CAN condense or remove:
- Verbose feature descriptions
- Repeated explanations of the same concept
- Implementation narratives (keep only learnings)
- Overly detailed module descriptions
- Changelog-style feature sections (integrate learnings instead)
- Historical implementation details without future value

## Expected Structure

Optimize for ~$TARGET_MIN-$TARGET_MAX lines with:
- **Project Overview** (5-10 lines) - Mission, users, architecture, tech stack
- **Module Directory** (40-80 lines) - Full names with clear, concise descriptions
- **Tech Stack & Patterns** (60-80 lines) - Clear patterns with explanations (not cryptic one-liners)
- **Development Guidelines** (40-60 lines) - Critical best practices, pitfalls, and workflow tips
- **NO separate feature section** - Integrate learnings where they belong

## Quality Guidelines

- **Clarity over brevity**: Public functions in main context module delegate to sub-modules instead of API to sub-modules
- **Actionable knowledge**: Focus on patterns and pitfalls that help future development
- **Remove changelog content**: No Completed feature lists - integrate the learnings instead

Remember: This file needs to fit efficiently in Claude's context alongside:
- Feature context (CONTEXT.md): 200-300 lines of active work and learnings
- Plan file (PLAN.md): 50-100 lines of implementation steps

Start by reading the current PROJECT_CONTEXT.md and create an optimized version that fits the target range."

echo "🎯 Context consolidation ready!"

# Load AI agent configuration
CONFIG_FILE="$HOME/.ocg/config.json"
if [ -f "$CONFIG_FILE" ]; then
    AI_AGENT=$(jq -r '.default_agent // "claude"' "$CONFIG_FILE")
else
    AI_AGENT="claude"
fi

echo "🤖 Starting $AI_AGENT with Opus model for thorough analysis..."

cd "$REPO_ROOT"

# Create temporary prompt file
PROMPT_FILE=$(mktemp)
trap "rm -f $PROMPT_FILE" EXIT
echo "$CONSOLIDATE_PROMPT" >"$PROMPT_FILE"

# Run AI agent
"$SCRIPT_DIR/ai-agents/run-ai.sh" "$AI_AGENT" "opus" "$PROMPT_FILE"
