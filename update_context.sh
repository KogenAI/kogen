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

I need you to integrate the archived feature context from \`codegen/contexts/$FEATURE_NAME.md\` into the main \`codegen/PROJECT_CONTEXT.md\` file to incorporate learnings from this completed feature implementation.

## Your Task

Please review the archived feature context and integrate its learnings into \`codegen/PROJECT_CONTEXT.md\` with:

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

- \`codegen/plans/$FEATURE_NAME.md\` - The feature plan
- \`codegen/PROJECT_CONTEXT.md\` - The project context to update"

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

CONTEXT_UPDATE_PROMPT="$CONTEXT_UPDATE_PROMPT, and also check the original feature plan. Then update the main PROJECT_CONTEXT.md with the learnings from this feature development.**"

echo "$CONTEXT_UPDATE_PROMPT" | pbcopy

open_cursor_agent_mode() {
    if ! pgrep -f "Cursor" >/dev/null 2>&1; then
        echo "⚠️  Cursor not running - please open Cursor and run update-context again"
        return 1
    fi

    osascript <<EOF >/dev/null 2>&1
tell application "Cursor"
    activate
    delay 1
    
    -- Ensure Cursor window is frontmost and focused
    tell application "System Events"
        tell process "Cursor"
            set frontmost to true
            delay 0.5
        end tell
        
        -- Open Agent Mode with Cmd+I
        keystroke "i" using {command down}
        delay 1
        
        -- Clear any existing content
        keystroke "a" using {command down}
        delay 0.5
        
        -- Paste the content using Cmd+V
        keystroke "v" using {command down}
        delay 0.5
        
        -- Don't auto-submit, let user review and press Enter manually
    end tell
end tell
EOF
}

echo ""
echo "🎯 Context update ready!"
echo "📋 Opening Cursor Agent mode..."

if open_cursor_agent_mode; then
    echo "✅ Cursor Agent mode opened with context update prompt!"
    echo "👉 Review the prompt and press Enter to start context update"
else
    echo "📋 Manual steps:"
    echo "   1. Open Cursor in this project"
    echo "   2. Press Cmd+I (Agent mode)"
    echo "   3. The context update prompt is copied to your clipboard - paste it"
    echo "   4. Press Enter to start context update"
fi

echo ""
echo "📝 Feature plan: $PLAN_FILE"
if [ "$CONTEXT_EXISTS" = true ]; then
    echo "📄 Archived context: $CONTEXT_FILE"
fi
echo "🗂️  Project context: $REPO_ROOT/codegen/PROJECT_CONTEXT.md"
echo ""
echo "💡 This will update the main PROJECT_CONTEXT.md with learnings from the $FEATURE_NAME feature development"
