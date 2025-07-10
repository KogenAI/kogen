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

# Create AGENTS.md if it doesn't exist (generic AI assistant instructions)
if [ ! -f "$REPO_ROOT/AGENTS.md" ]; then
    cp "$SCRIPT_DIR/templates/AGENTS.md" "$REPO_ROOT/AGENTS.md"
    echo "✅ Created AGENTS.md with rule system references"
else
    echo "ℹ️  AGENTS.md already exists, skipping..."
fi

# Create CLAUDE.md symlink for backward compatibility
if [ ! -e "$REPO_ROOT/CLAUDE.md" ]; then
    ln -sf "AGENTS.md" "$REPO_ROOT/CLAUDE.md"
    echo "✅ Created CLAUDE.md symlink for backward compatibility"
else
    echo "ℹ️  CLAUDE.md already exists, skipping..."
fi

# Create symbolic link to rules if it doesn't exist
if [ ! -L "$REPO_ROOT/codegen/rules" ] && [ ! -d "$REPO_ROOT/codegen/rules" ]; then
    if [ -n "$OCG_RULES_DIR" ] && [ -d "$OCG_RULES_DIR" ]; then
        ln -s "$OCG_RULES_DIR" "$REPO_ROOT/codegen/rules"
        echo "✅ Created symbolic link to development rules at: $OCG_RULES_DIR"
    else
        echo "⚠️  Development rules not found. Set OCG_RULES_DIR environment variable."
        echo "   Example: export OCG_RULES_DIR=~/Areas/Optimum/context/rules"
        echo ""
        echo "   You can manually create the symbolic link later with:"
        echo "   ln -s <path-to-rules> $REPO_ROOT/codegen/rules"
    fi
else
    echo "ℹ️  Rules directory already exists, skipping..."
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

1. **Replace ALL placeholder text** in \`./codegen/PROJECT_CONTEXT.md\` with real project details
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

**Start by opening and reviewing \`./codegen/PROJECT_CONTEXT.md\`, then begin your analysis.**"

open_cursor_setup_chat() {
    if ! pgrep -f "Cursor" >/dev/null 2>&1; then
        echo "⚠️  Cursor not running - please open Cursor and run setup again"
        return 1
    fi

    osascript <<EOF >/dev/null 2>&1
EOF
}

# Update .gitignore with Optimum Codegen entries
update_ignore_file() {
    local file="$1"
    local comment="# Optimum Codegen"
    local block="# Optimum Codegen
/.vscode/
/codegen/
/AGENTS.md
/CLAUDE.md
.mcp.json
*.code-workspace"

    if [ -f "$file" ]; then
        # Check if our entries already exist
        if ! grep -q "$comment" "$file" 2>/dev/null; then
            echo "" >>"$file"
            echo "$block" >>"$file"
            return 0
        fi
    else
        # Create new file
        echo "$block" >"$file"
        return 0
    fi
    return 1
}

echo "🔧 Updating ignore files..."
if update_ignore_file "$REPO_ROOT/.gitignore"; then
    echo "✅ Updated .gitignore with Optimum Codegen entries"
else
    echo "ℹ️  .gitignore already contains Optimum Codegen entries"
fi

if update_ignore_file "$REPO_ROOT/.dockerignore"; then
    echo "✅ Updated .dockerignore with Optimum Codegen entries"
else
    echo "ℹ️  .dockerignore already contains Optimum Codegen entries (or file doesn't exist)"
fi

echo ""
echo "🗂️  Files created:"
echo "   - AGENTS.md (AI assistant instructions)"
echo "   - CLAUDE.md (symlink for backward compatibility)"
echo "   - codegen/PROJECT_CONTEXT.md (project knowledge base)"
echo "   - codegen/rules/ (symbolic link to development rules)"
echo "   - Updated .gitignore and .dockerignore"
echo ""
echo "After PROJECT_CONTEXT.md is filled, you can create workspaces with: $OCG_CMD new <feature-name>"

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

echo "🤖 Starting $AI_ASSISTANT with Opus model for setup..."

export SHELL=/bin/bash

case "$AI_ASSISTANT" in
claude)
    if command -v claude >/dev/null 2>&1; then
        exec claude --model opus "$SETUP_PROMPT"
    else
        echo "⚠️  Claude CLI not found. Please install Claude CLI first and try again."
        exit 1
    fi
    ;;
opencode)
    if command -v opencode >/dev/null 2>&1; then
        # Get provider and map model name
        PROVIDER=$(get_provider "opencode")
        OC_MODEL=$(map_model "opus" "opencode" "$PROVIDER")
        exec opencode run --model "$PROVIDER/$OC_MODEL" "$SETUP_PROMPT"
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
