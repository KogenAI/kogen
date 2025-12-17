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

# Check for modular plan structure first, then single file
if [ -d "$REPO_ROOT/codegen/plans/$FEATURE_NAME" ]; then
    PLAN_FILE="$REPO_ROOT/codegen/plans/$FEATURE_NAME/"
    PLAN_TYPE="modular"
elif [ -f "$REPO_ROOT/codegen/plans/$FEATURE_NAME.md" ]; then
    PLAN_FILE="$REPO_ROOT/codegen/plans/$FEATURE_NAME.md"
    PLAN_TYPE="single"
else
    echo "❌ Error: Plan not found"
    echo "Expected either:"
    echo "  - Modular: codegen/plans/$FEATURE_NAME/"
    echo "  - Single file: codegen/plans/$FEATURE_NAME.md"
    exit 1
fi

CONTEXT_FOLDER="$REPO_ROOT/codegen/contexts/$FEATURE_NAME"
CONTEXT_FILE="$CONTEXT_FOLDER/CONTEXT.md"
CONTEXT_EXISTS=false
if [ -d "$CONTEXT_FOLDER" ] && [ -f "$CONTEXT_FILE" ]; then
    CONTEXT_EXISTS=true
elif [ -f "$REPO_ROOT/codegen/contexts/$FEATURE_NAME.md" ]; then
    # Legacy single file format
    CONTEXT_FILE="$REPO_ROOT/codegen/contexts/$FEATURE_NAME.md"
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

## Size Awareness

PROJECT_CONTEXT.md should remain concise (150-250 lines). Do NOT add a feature section - instead integrate learnings directly into relevant existing sections.

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

## Additional Updates

If applicable, also update:

- **Figma Design Files** - Update Figma node ID to Phoenix component mappings, design system rules, and token mappings if UI components were created/modified
- **Rules** - Extract important lessons and patterns that could be useful for future development into \`./codegen/rules/\`
  - **Planning rules** are in \`./codegen/rules/planning/\` (bird-eye.md, detailed.md, plan-verification.md)
  - **Shared planning rules** are in \`./codegen/rules/planning.md\`

## Guidelines

- **Use the archived feature context as your primary source** - it contains the actual implementation details and learnings
- **Integrate learnings, not changelog entries** - Add patterns/pitfalls to relevant sections, not \"✅ Feature X completed\"
- **Keep it concise** - If PROJECT_CONTEXT.md would exceed 250 lines, consolidate further
- **Focus on reusable knowledge** - Patterns, pitfalls, and approaches that help future development
- **Update module descriptions** - Add new capabilities to existing module descriptions
- **Enhance patterns section** - Add new patterns discovered during implementation
- **Update the \"Last Updated\" timestamp** with a brief note about what knowledge was added
- **NO feature lists** - Integrate the knowledge where it belongs in the structure

## Files to Review"

if [ "$PLAN_TYPE" = "modular" ]; then
    CONTEXT_UPDATE_PROMPT="$CONTEXT_UPDATE_PROMPT
- \`./codegen/plans/$FEATURE_NAME/\` - The feature plan (modular structure with overview.md and steps/)"
else
    CONTEXT_UPDATE_PROMPT="$CONTEXT_UPDATE_PROMPT
- \`./codegen/plans/$FEATURE_NAME.md\` - The feature plan (single file)"
fi

CONTEXT_UPDATE_PROMPT="$CONTEXT_UPDATE_PROMPT
- \`./codegen/PROJECT_CONTEXT.md\` - The project context to update
- \`./codegen/FIGMA_MAP.md\` - Figma node ID to component mappings (if it exists and is relevant)
- \`./codegen/FIGMA_DESIGN_SYSTEM_RULES.md\` - Figma design system rules (if it exists and is relevant)
- \`./codegen/FIGMA_TOKEN_MAPPING.md\` - Figma token mappings (if it exists and is relevant)"

if [ "$CONTEXT_EXISTS" = true ]; then
    if [ -d "$CONTEXT_FOLDER" ]; then
        CONTEXT_UPDATE_PROMPT="$CONTEXT_UPDATE_PROMPT
- \`codegen/contexts/$FEATURE_NAME/CONTEXT.md\` - Archived main feature context
- \`codegen/contexts/$FEATURE_NAME/context/\` - Archived step context files (if any)
- \`codegen/contexts/$FEATURE_NAME/FIGMA_*.md\` - Archived modified Figma files (if any)"
    else
        CONTEXT_UPDATE_PROMPT="$CONTEXT_UPDATE_PROMPT
- \`codegen/contexts/$FEATURE_NAME.md\` - Archived feature context (legacy format) with implementation details and learnings"
    fi
fi

CONTEXT_UPDATE_PROMPT="$CONTEXT_UPDATE_PROMPT
- Any implemented code that was created or modified for this feature

This updated context will help future AI sessions understand both the existing project structure and the patterns established by this completed feature.

**Start by reviewing the current PROJECT_CONTEXT.md"

if [ "$CONTEXT_EXISTS" = true ]; then
    CONTEXT_UPDATE_PROMPT="$CONTEXT_UPDATE_PROMPT, then CAREFULLY REVIEW the archived feature context in \`codegen/contexts/$FEATURE_NAME.md\` (this contains the actual implementation details)"
fi

CONTEXT_UPDATE_PROMPT="$CONTEXT_UPDATE_PROMPT, and also check the original feature plan. Then update the main PROJECT_CONTEXT.md with the learnings from this feature development.**"

# Add the Integration Example and Recipe Extraction content
CONTEXT_UPDATE_PROMPT="$CONTEXT_UPDATE_PROMPT

## Integration Example

Instead of adding:
\`\`\`markdown
### Digital Contract Signing
- **Status**: ✅ Production Ready
- **Provider-agnostic architecture with SignWell/Mock**
- **In-memory session management**
\`\`\`

Integrate into existing sections:
- Add \"DigitalSignatures\" to Infrastructure Modules with description
- Add \"Provider-agnostic interfaces using behaviours\" to Architecture Principles
- Add any new pitfalls to Common Pitfalls section

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

Note: Only create recipes for truly reusable patterns, not feature-specific implementations.

## Rules: Enhance First, Create Rarely

**IMPORTANT**: Rules are compressed knowledge and space is precious. New rules should be created very rarely.

Identify key lessons and prioritize this way:
- Important architectural decisions or constraints
- Common pitfalls and how to avoid them  
- Best practices discovered during implementation
- Integration patterns that work well
- Performance considerations
- Security patterns

**Strongly preferred approach** (95% of cases):
1. Check existing rules in ./codegen/rules/ that could be enhanced
2. Add learnings to relevant existing rules (e.g., phoenix-testing.md, elixir-ci.md)
3. Most learnings should stay in PROJECT_CONTEXT.md or become recipes

**Create new rules very rarely** (5% of cases), only when:
- The knowledge is truly foundational to the entire project
- No existing rule can be enhanced to accommodate it
- The pattern will be referenced constantly across many features
- Loss of this knowledge would be architecturally significant

If you must create a new rule, use this template:

\`\`\`markdown
# Rule: [Descriptive Title]

## Context
[When does this rule apply?]

## Rule
[The specific rule or principle to follow]

## Rationale
[Why is this rule important? What problems does it prevent?]

## Examples
[Good and bad examples demonstrating the rule]

## Exceptions
[When might this rule not apply?]

## Related Rules
- [Links to related rules if any]
\`\`\`

## Figma Design File Updates

If this feature involved UI components that map to Figma designs:
1. Check if Figma files exist in ./codegen/ (FIGMA_MAP.md, FIGMA_DESIGN_SYSTEM_RULES.md, FIGMA_TOKEN_MAPPING.md)
2. If they exist and UI components were created/modified, update the relevant files:
   - **FIGMA_MAP.md**: Add new Figma node IDs to Phoenix component mappings
   - **FIGMA_DESIGN_SYSTEM_RULES.md**: Update design system rules if design patterns changed
   - **FIGMA_TOKEN_MAPPING.md**: Update token mappings if design tokens were modified
3. Update existing mappings if component names or structures changed
4. Follow the existing format in each file"

# Merge archived Figma files back to main repo if they exist
if [ -d "$CONTEXT_FOLDER" ]; then
    figma_files_merged=false
    for figma_file in "FIGMA_MAP.md" "FIGMA_DESIGN_SYSTEM_RULES.md" "FIGMA_TOKEN_MAPPING.md"; do
        archived_figma_file="$CONTEXT_FOLDER/$figma_file"
        main_figma_file="$REPO_ROOT/codegen/$figma_file"

        if [ -f "$archived_figma_file" ]; then
            # Check if main repo file is different or doesn't exist
            if [ ! -f "$main_figma_file" ] || ! cmp -s "$archived_figma_file" "$main_figma_file"; then
                cp "$archived_figma_file" "$main_figma_file"
                echo "🎨 Merged archived Figma file back to main repo: $figma_file"
                figma_files_merged=true
            fi
        fi
    done

    if [ "$figma_files_merged" = true ]; then
        echo "✅ Figma files merged from archived context to main repository"
    fi
fi

echo ""
echo "🎯 Context update ready!"

# Ensure recipes and rules directories exist
RECIPES_DIR="$REPO_ROOT/codegen/recipes"
RULES_DIR="$REPO_ROOT/codegen/rules"

if [ ! -d "$RECIPES_DIR" ]; then
    echo "📚 Creating recipes directory at: $RECIPES_DIR"
    mkdir -p "$RECIPES_DIR"
fi

if [ ! -d "$RULES_DIR" ]; then
    echo "📋 Creating rules directory at: ./codegen/rules/"
    mkdir -p "$RULES_DIR"
fi

# Load AI agent configuration
CONFIG_FILE="$HOME/.ocg/config.json"
if [ -f "$CONFIG_FILE" ]; then
    AI_AGENT=$(jq -r '.default_agent // "claude"' "$CONFIG_FILE")
else
    AI_AGENT="claude"
fi

echo "🤖 Starting $AI_AGENT with Sonnet model for context update..."

cd "$REPO_ROOT"

# Create temporary prompt file
PROMPT_FILE=$(mktemp)
trap "rm -f $PROMPT_FILE" EXIT
echo "$CONTEXT_UPDATE_PROMPT" >"$PROMPT_FILE"

# Run AI agent
"$SCRIPT_DIR/ai-agents/run-ai.sh" "$AI_AGENT" "sonnet" "$PROMPT_FILE"

echo ""
echo "📝 Feature plan: $PLAN_FILE"
if [ "$CONTEXT_EXISTS" = true ]; then
    echo "📄 Archived context: $CONTEXT_FILE"
fi
echo "🗂️  Project context: $REPO_ROOT/codegen/PROJECT_CONTEXT.md"
echo ""
echo "💡 This will update the main PROJECT_CONTEXT.md with learnings from the $FEATURE_NAME feature development"
echo "📚 Reusable patterns will be extracted to: ~/Areas/Optimum/context/recipes/"
echo "📋 Existing rules in ./codegen/rules/ will be enhanced (new rules created very rarely)"
echo "🎨 Figma files (FIGMA_MAP.md, FIGMA_DESIGN_SYSTEM_RULES.md, FIGMA_TOKEN_MAPPING.md) will be updated if UI components were created/modified"
