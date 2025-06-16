#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"
source "$SCRIPT_DIR/utils.sh"

REPO_ROOT="$TARGET_REPO_PATH"

echo "🚀 Setting up Optimum Codegen for project..."
echo "📁 Project: $REPO_ROOT"

mkdir -p "$REPO_ROOT/codegen"
mkdir -p "$REPO_ROOT/codegen/plans"
mkdir -p "$REPO_ROOT/codegen/contexts"

if [ ! -f "$REPO_ROOT/codegen/PROJECT_CONTEXT.md" ]; then
    cp "$SCRIPT_DIR/templates/PROJECT_CONTEXT.md" "$REPO_ROOT/codegen/PROJECT_CONTEXT.md"

    PROJECT_NAME=$(basename "$REPO_ROOT")
    CURRENT_DATE=$(date +"%B %d, %Y")

    sed -i '' "s|{{CURRENT_DATE}}|$CURRENT_DATE|g" "$REPO_ROOT/codegen/PROJECT_CONTEXT.md"
    sed -i '' "s|{{PROJECT_NAME}}|$PROJECT_NAME|g" "$REPO_ROOT/codegen/PROJECT_CONTEXT.md"

    echo "✅ Created PROJECT_CONTEXT.md template"
else
    echo "ℹ️  PROJECT_CONTEXT.md already exists, skipping..."
fi

PROJECT_INFO=""

if [ -f "$REPO_ROOT/.tool-versions" ]; then
    PROJECT_INFO+="🔍 Found .tool-versions file with version information"$'\n'
fi

if [ -f "$REPO_ROOT/Dockerfile" ]; then
    PROJECT_INFO+="🔍 Found Dockerfile with deployment configuration"$'\n'
fi

if [ -f "$REPO_ROOT/mix.exs" ]; then
    PROJECT_INFO+="🔍 Found mix.exs with dependency and version information"$'\n'
fi

if [ -d "$REPO_ROOT/test/support/fixtures" ]; then
    PROJECT_INFO+="🔍 Found fixtures in test/support/ - project uses fixture-based testing"$'\n'
elif [ -d "$REPO_ROOT/test/support/factory" ]; then
    PROJECT_INFO+="🔍 Found factory in test/support/ - project uses factory-based testing"$'\n'
fi

SETUP_PROMPT="# Project Context Setup

I need you to analyze this Phoenix/Elixir codebase and fill out the PROJECT_CONTEXT.md template completely. This will serve as the foundational knowledge for all future AI development sessions.

## Your Task

Please analyze the codebase and:

1. **Replace ALL placeholder text** in \`codegen/PROJECT_CONTEXT.md\` with real project details
2. **Document the actual architecture** - what patterns are really used?
3. **List real modules** - what contexts, schemas, and LiveViews exist?
4. **Identify integration points** - how do different parts connect?
5. **Document coding conventions** - what patterns do you see in the existing code?
6. **Note any pitfalls** - what could trip up future development?

## Guidelines

- **Be specific, not generic** - use actual module names, not placeholders
- **Be comprehensive** - this is a one-time setup, so be thorough
- **Focus on architecture** - how is the code organized and why?
- **Include examples** - reference actual files and patterns you find
- **Update the timestamp** - change the \"Last Updated\" date to today's date

## Files to Focus On

- \`lib/*/\` - Main application contexts
- \`lib/*_web/\` - Web layer (controllers, views, LiveViews)
- \`priv/repo/\` - Database migrations and seeds
- \`config/\` - Application configuration
- \`test/\` - Test patterns and structure
- \`.tool-versions\` - Runtime versions
- \`mix.exs\` - Dependencies and project configuration
- \`Dockerfile\` - Deployment configuration

## Important Notes
$PROJECT_INFO

This PROJECT_CONTEXT.md will be used by all future AI sessions to understand the project without re-analyzing the entire codebase.

**Start by opening and reviewing \`codegen/PROJECT_CONTEXT.md\`, then begin your analysis.**"

echo "$SETUP_PROMPT" | pbcopy

open_cursor_setup_chat() {
    if ! pgrep -f "Cursor" >/dev/null 2>&1; then
        echo "⚠️  Cursor not running - please open Cursor and run setup again"
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
        
        -- Open Chat in Setup Mode with Ctrl+Shift+Cmd+S
        keystroke "s" using {control down, shift down, command down}
        delay 1
        
        -- Clear any existing content in chat
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
echo "🎯 Setup complete!"
echo "📋 Opening Cursor chat in Setup mode..."

if open_cursor_setup_chat; then
    echo "✅ Cursor chat opened with setup prompt!"
    echo "👉 Review the prompt and press Enter to start analysis"
else
    echo "📋 Manual steps:"
    echo "   1. Open Cursor in this project"
    echo "   2. Press Ctrl+Shift+Cmd+S (Setup mode)"
    echo "   3. The setup prompt is copied to your clipboard - paste it"
    echo "   4. Press Enter to start analysis"
fi

echo ""
echo "🗂️  Template created at: codegen/PROJECT_CONTEXT.md"
echo ""
echo "After PROJECT_CONTEXT.md is filled, you can create workspaces with: $OCG_CMD new <feature-name>"
