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

# Validate OCG_CONTEXT_DIR is set
if [ -z "$OCG_CONTEXT_DIR" ]; then
    echo "❌ ERROR: OCG_CONTEXT_DIR environment variable is required but not set."
    echo "   This variable should point to your Optimum context directory."
    echo ""
    echo "   Example: export OCG_CONTEXT_DIR=~/Areas/Optimum/context"
    echo ""
    echo "   Add this to your shell profile (~/.bashrc, ~/.zshrc, etc.) to persist:"
    echo "   echo 'export OCG_CONTEXT_DIR=~/Areas/Optimum/context' >> ~/.zshrc"
    exit 1
fi

# Validate OCG_CONTEXT_DIR directory exists
if [ ! -d "$OCG_CONTEXT_DIR" ]; then
    echo "❌ ERROR: OCG_CONTEXT_DIR points to non-existent directory: $OCG_CONTEXT_DIR"
    echo "   Please ensure the directory exists or update the OCG_CONTEXT_DIR variable."
    exit 1
fi

# Create symbolic link to rules if it doesn't exist
if [ ! -L "$REPO_ROOT/codegen/rules" ] && [ ! -d "$REPO_ROOT/codegen/rules" ]; then
    if [ -d "$OCG_CONTEXT_DIR/rules" ]; then
        ln -s "$OCG_CONTEXT_DIR/rules" "$REPO_ROOT/codegen/rules"
        echo "✅ Created symbolic link to development rules at: $OCG_CONTEXT_DIR/rules"
    else
        echo "❌ ERROR: Rules directory not found at: $OCG_CONTEXT_DIR/rules"
        echo "   Please ensure the rules directory exists in your OCG_CONTEXT_DIR."
        exit 1
    fi
fi

# Create symbolic link to recipes if it doesn't exist
if [ ! -L "$REPO_ROOT/codegen/recipes" ] && [ ! -d "$REPO_ROOT/codegen/recipes" ]; then
    if [ -d "$OCG_CONTEXT_DIR/recipes" ]; then
        ln -s "$OCG_CONTEXT_DIR/recipes" "$REPO_ROOT/codegen/recipes"
        echo "✅ Created symbolic link to development recipes at: $OCG_CONTEXT_DIR/recipes"
    else
        echo "❌ ERROR: Recipes directory not found at: $OCG_CONTEXT_DIR/recipes"
        echo "   Please ensure the recipes directory exists in your OCG_CONTEXT_DIR."
        exit 1
    fi
else
    echo "ℹ️  Recipes directory already exists, skipping..."
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
7. **Create Figma files if needed** - if this project uses Figma designs, create:
   - \`./codegen/FIGMA_MAP.md\` - Maps Figma components to code implementation
   - \`./codegen/FIGMA_DESIGN_SYSTEM_RULES.md\` - Design system implementation rules
   - \`./codegen/FIGMA_TOKEN_MAPPING.md\` - Maps design tokens to CSS/Tailwind classes

## Guidelines

- **Be specific, not generic** - use actual module names, not placeholders
- **Be comprehensive** - this is a one-time setup, so be thorough
- **Focus on architecture** - how is the code organized and why?
- **Include examples** - reference actual files and patterns you find
- **Update the timestamp** - change the \"Last Updated\" date to today's date
- **Create Figma files only if needed** - only create them if you find evidence of Figma usage in the project

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
opencode.json
*.code-workspace"

    if [ -f "$file" ]; then
        # Check if our entries already exist and are properly formatted
        if ! grep -q "$comment" "$file" 2>/dev/null; then
            # Clean up any trailing blank lines first
            if [ -s "$file" ]; then
                tail -r "$file" | sed '/./,$!d' | tail -r >"$file.tmp" && mv "$file.tmp" "$file"
                # Add exactly one blank line before our block
                echo "" >>"$file"
            fi
            echo "$block" >>"$file"
            return 0
        else
            # Block exists - just skip
            return 1
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
# Update config/dev.exs to support dynamic ports and database partitions
echo "🔧 Updating config/dev.exs for OCG compatibility..."

DEV_CONFIG="$REPO_ROOT/config/dev.exs"
if [ -f "$DEV_CONFIG" ]; then
    # Get app name from mix.exs
    APP_NAME=$(grep -E "app: :" "$REPO_ROOT/mix.exs" | head -1 | sed -E 's/.*app: :([^,]+).*/\1/')

    # Update database configuration for partitions
    if ! grep -q "MIX_DEV_PARTITION" "$DEV_CONFIG"; then
        sed -i '' "s/database: \"${APP_NAME}_dev\"/database: \"${APP_NAME}_dev#{System.get_env(\\\"MIX_DEV_PARTITION\\\")}\"/" "$DEV_CONFIG"
        echo "✅ Added database partition support to config/dev.exs"
    fi

    # Update port configuration only (keep localhost binding)
    if ! grep -q "System.get_env(\"PORT\"" "$DEV_CONFIG"; then
        sed -i '' 's/http: \[ip: {[^}]*}, port: [0-9]*\]/http: [ip: {127, 0, 0, 1}, port: String.to_integer(System.get_env("PORT") || "4000")]/' "$DEV_CONFIG"
        echo "✅ Added PORT environment variable support to config/dev.exs"
    fi
else
    echo "⚠️  config/dev.exs not found - skipping Phoenix configuration"
fi

# Create empty .env file if it doesn't exist
if [ ! -f "$REPO_ROOT/.env" ]; then
    touch "$REPO_ROOT/.env"
    echo "✅ Created empty .env file"
else
    echo "ℹ️  .env file already exists, skipping..."
fi

# Set up MCP integration (Tidewave, Figma, Playwright)
echo ""
echo "🔧 Setting up MCP integration..."

# Add Tidewave dependency to mix.exs if it doesn't exist
if [ -f "$REPO_ROOT/mix.exs" ] && ! grep -q "tidewave" "$REPO_ROOT/mix.exs"; then
    # Add tidewave as the last dependency after bandit
    if grep -q "defp deps do" "$REPO_ROOT/mix.exs"; then
        # Add comma to bandit and insert tidewave dependency
        sed -i '' 's/{:bandit, "~> 1\.5"}$/{:bandit, "~> 1.5"},/' "$REPO_ROOT/mix.exs"
        sed -i '' '/      {:bandit, "~> 1\.5"},$/a\
      {:tidewave, "~> 0.1", only: :dev}' "$REPO_ROOT/mix.exs"
        # Fix closing bracket on same line by adding newline before it
        sed -i '' 's/}    ]/}\
    ]/' "$REPO_ROOT/mix.exs"
        echo "✅ Added Tidewave dependency to mix.exs"
    else
        echo "⚠️  Could not find dependency pattern in mix.exs, skipping Tidewave dependency"
    fi
fi

# Add Tidewave plug to endpoint.ex
ENDPOINT_FILE="$REPO_ROOT/lib/${APP_NAME}_web/endpoint.ex"
if [ -f "$ENDPOINT_FILE" ] && ! grep -q "Tidewave" "$ENDPOINT_FILE"; then
    # Find the line with the code reloading comment and insert Tidewave plug before it
    COMMENT_LINE=$(grep -n "# Code reloading can be explicitly enabled" "$ENDPOINT_FILE" | cut -d: -f1)
    if [ -n "$COMMENT_LINE" ]; then
        # Insert the Tidewave plug before the code reloading comment
        sed -i '' "${COMMENT_LINE}i\\
  if Code.ensure_loaded?(Tidewave) do\\
    plug Tidewave\\
  end\\
\\
" "$ENDPOINT_FILE"
        echo "✅ Added Tidewave plug to endpoint.ex"
    else
        echo "⚠️  Could not find code reloading comment, skipping Tidewave plug"
    fi
fi

# Create .mcp.json from template
if [ ! -f "$REPO_ROOT/.mcp.json" ]; then
    sed -e "s/{{PORT}}/4000/g" \
        -e "s/{{PLAYWRIGHT_MCP_PORT}}/8900/g" \
        "$SCRIPT_DIR/templates/.mcp.json" >"$REPO_ROOT/.mcp.json"
    echo "✅ Created .mcp.json configuration"
fi

# Create opencode.json from template
if [ ! -f "$REPO_ROOT/opencode.json" ]; then
    sed -e "s/{{PORT}}/4000/g" \
        -e "s/{{PLAYWRIGHT_MCP_PORT}}/8900/g" \
        "$SCRIPT_DIR/templates/.opencode-mcp.json" >"$REPO_ROOT/opencode.json"
    echo "✅ Created opencode.json configuration"
fi

# Install dependencies if mix.exs was modified
if [ -f "$REPO_ROOT/mix.exs" ] && command -v mix >/dev/null 2>&1; then
    echo "📦 Installing dependencies..."
    cd "$REPO_ROOT"
    mix deps.get >/dev/null 2>&1
    echo "✅ Dependencies installed"
fi

echo "After PROJECT_CONTEXT.md is filled, you can create workspaces with: $OCG_CMD new <feature-name>"

# Load AI assistant configuration
CONFIG_FILE="$HOME/.ocg/config.json"
if [ -f "$CONFIG_FILE" ]; then
    AI_ASSISTANT=$(jq -r '.default_assistant // "claude"' "$CONFIG_FILE")
else
    AI_ASSISTANT="claude"
fi

echo "🤖 Starting $AI_ASSISTANT with Opus model for setup..."

cd "$REPO_ROOT"

# Create temporary prompt file
PROMPT_FILE=$(mktemp)
trap "rm -f $PROMPT_FILE" EXIT
echo "$SETUP_PROMPT" >"$PROMPT_FILE"

# Run AI assistant
"$SCRIPT_DIR/ai-assistants/run-ai.sh" "$AI_ASSISTANT" "opus" "$PROMPT_FILE"
