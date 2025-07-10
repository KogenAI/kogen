#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"
source "$SCRIPT_DIR/utils.sh"

FEATURE_NAME="$1"
REPO_ROOT="$TARGET_REPO_PATH"

if [ -z "$FEATURE_NAME" ]; then
    echo "❌ Error: Feature name is required"
    echo "Usage: $0 <feature-name>"
    echo "Example: $0 dashboard-redesign"
    exit 1
fi

if [ ! -f "$REPO_ROOT/codegen/PROJECT_CONTEXT.md" ]; then
    echo "❌ Error: PROJECT_CONTEXT.md not found"
    echo "Please run '$OCG_CMD setup' first to initialize the project context"
    exit 1
fi

PLAN_FILE="$REPO_ROOT/codegen/plans/$FEATURE_NAME.md"
if [ ! -f "$PLAN_FILE" ]; then
    echo "❌ Error: Plan file not found: $PLAN_FILE"
    echo "Please create a plan file first at: codegen/plans/$FEATURE_NAME.md"
    exit 1
fi

CONTEXT_FILE="$REPO_ROOT/codegen/contexts/$FEATURE_NAME.md"
CONTEXT_EXISTS=false
if [ -f "$CONTEXT_FILE" ]; then
    CONTEXT_EXISTS=true
fi

echo "🔄 Updating project context for feature: $FEATURE_NAME"
echo "📁 Project: $REPO_ROOT"
echo "📋 Plan: $PLAN_FILE"
if [ "$CONTEXT_EXISTS" = true ]; then
    echo "📄 Existing context: $CONTEXT_FILE"
fi

CONTEXT_UPDATE_PROMPT="# Project Context Update for Feature: $FEATURE_NAME

I need you to integrate the archived feature context from \`./codegen/contexts/$FEATURE_NAME.md\` into the main \`./codegen/PROJECT_CONTEXT.md\` file to incorporate learnings from this completed feature implementation.

## Your Task

Please review the archived feature context and integrate its learnings into \`./codegen/PROJECT_CONTEXT.md\` with:

1. **New modules/contexts** that were created for this feature
2. **Modified existing modules** that were affected during development
3. **New dependencies** or integrations that were added
4. **Database changes** (new tables, fields, relationships) that were implemented
5. **API endpoints** or LiveView routes that were added/modified
6. **Testing patterns** that were established for this feature
7. **Deployment considerations** that were discovered
8. **Architectural learnings** from the feature development

## Guidelines

- **Use the archived feature context as your primary source** - it contains the actual implementation details and learnings
- **Integrate the real implementation details** - use actual module names and patterns from the development
- **Focus on what was actually built** - not just what was planned
- **Update the \"Last Updated\" timestamp** to reflect this context update
- **Add a note** about this feature being completed and context updated
- **Document any deviations** from the original plan and why they occurred
- **Include any new patterns** or conventions established during development

## Files to Review

- \`./codegen/plans/$FEATURE_NAME.md\` - The feature plan
- \`./codegen/PROJECT_CONTEXT.md\` - The project context to update"

if [ "$CONTEXT_EXISTS" = true ]; then
    CONTEXT_UPDATE_PROMPT="$CONTEXT_UPDATE_PROMPT
- \`codegen/contexts/$FEATURE_NAME.md\` - Archived feature context with implementation details and learnings"
fi

CONTEXT_UPDATE_PROMPT="$CONTEXT_UPDATE_PROMPT
- Any implemented code that was created or modified for this feature

This updated context will help future AI sessions understand both the existing project structure and the patterns established by this completed feature.

**Start by reviewing the current PROJECT_CONTEXT.md"

if [ "$CONTEXT_EXISTS" = true ]; then
    CONTEXT_UPDATE_PROMPT="$CONTEXT_UPDATE_PROMPT, then CAREFULLY REVIEW the archived feature context in \`codegen/contexts/$FEATURE_NAME.md\` (this contains the actual implementation details)"
fi

CONTEXT_UPDATE_PROMPT="$CONTEXT_UPDATE_PROMPT, and also check the original feature plan. Then update the main PROJECT_CONTEXT.md with the learnings from this feature development.**

## Recipe Extraction

Additionally, please identify if any techniques or patterns from this feature would make good reusable recipes. A recipe should be:
- A self-contained technique or pattern that could be reused in other projects
- General enough to apply beyond this specific feature
- Complex enough to warrant documentation (not trivial tasks)

Examples of good recipes:
- Data sanitization techniques for using production data locally
- Authentication patterns (OAuth, JWT, etc.)
- Complex database migration strategies
- Performance optimization techniques
- Testing patterns for specific scenarios
- Error handling and recovery patterns
- Integration patterns with third-party services

If you identify potential recipes:
1. Check if a similar recipe already exists in ~/Areas/Optimum/context/recipes/
2. If not, create a new recipe file with a descriptive name (e.g., data-sanitization-for-local-dev.md)
3. Use this template for the recipe:

\`\`\`markdown
# Recipe: [Descriptive Title]

## Problem
[What problem does this solve?]

## Solution
[High-level overview of the approach]

## Implementation
[Step-by-step implementation details with code examples]

## Considerations
- [Important things to consider]
- [Potential pitfalls]
- [When to use/not use this pattern]

## Example Usage
[Concrete example from the feature where this was applied]

## Related Recipes
- [Links to related recipes if any]
\`\`\`

Note: Only create recipes for truly reusable patterns, not feature-specific implementations."

echo ""
echo "🎯 Context update ready!"

# Ensure recipes directory exists
RECIPES_DIR="$HOME/Areas/Optimum/context/recipes"
if [ ! -d "$RECIPES_DIR" ]; then
    echo "📚 Creating recipes directory at: $RECIPES_DIR"
    mkdir -p "$RECIPES_DIR"
fi

# Load AI assistant configuration
CONFIG_FILE="$HOME/.ocg/config.json"
if [ -f "$CONFIG_FILE" ]; then
    AI_ASSISTANT=$(jq -r '.default_assistant // "claude"' "$CONFIG_FILE")
else
    AI_ASSISTANT="claude"
fi

# Source authentication check
source "$SCRIPT_DIR/ai-assistants/check-auth.sh"

# Check authentication
if ! check_assistant_auth "$AI_ASSISTANT"; then
    exit 1
fi

# Source model mapper
source "$SCRIPT_DIR/ai-assistants/model-mapper.sh"

echo "🤖 Starting $AI_ASSISTANT with Sonnet model for context update..."

cd "$REPO_ROOT"

export SHELL=/bin/bash

case "$AI_ASSISTANT" in
claude)
    if command -v claude >/dev/null 2>&1; then
        exec claude --model sonnet "$CONTEXT_UPDATE_PROMPT"
    else
        echo "⚠️  Claude CLI not found. Please install Claude CLI first and try again."
        exit 1
    fi
    ;;
opencode)
    if command -v opencode >/dev/null 2>&1; then
        # Get provider and map model name
        PROVIDER=$(get_provider "opencode")
        OC_MODEL=$(map_model "sonnet" "opencode" "$PROVIDER")
        exec opencode run --model "$PROVIDER/$OC_MODEL" "$CONTEXT_UPDATE_PROMPT"
    else
        echo "⚠️  OpenCode not found. Please install OpenCode first and try again."
        exit 1
    fi
    ;;
*)
    echo "❌ Unknown AI assistant: $AI_ASSISTANT"
    exit 1
    ;;
esac

echo ""
echo "📝 Feature plan: $PLAN_FILE"
if [ "$CONTEXT_EXISTS" = true ]; then
    echo "📄 Archived context: $CONTEXT_FILE"
fi
echo "🗂️  Project context: $REPO_ROOT/codegen/PROJECT_CONTEXT.md"
echo ""
echo "💡 This will update the main PROJECT_CONTEXT.md with learnings from the $FEATURE_NAME feature development"
echo "📚 Reusable patterns will be extracted to: ~/Areas/Optimum/context/recipes/"
