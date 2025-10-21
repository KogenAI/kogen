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

# Create PROJECT_CONTEXT.md - prefer project-specific context, fallback to template
PROJECT_NAME=$(basename "$REPO_ROOT")

# Validate OCG_CONTEXT_DIR is set early since we need it
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

PROJECT_CONTEXT_DIR="$OCG_CONTEXT_DIR/$PROJECT_NAME"

# Flag to track if we need AI analysis
NEEDS_AI_ANALYSIS=false

if [ -d "$PROJECT_CONTEXT_DIR" ] && [ -f "$PROJECT_CONTEXT_DIR/PROJECT_CONTEXT.md" ]; then
    # Project-specific PROJECT_CONTEXT.md exists, create or update symlink
    if [ -L "$REPO_ROOT/codegen/PROJECT_CONTEXT.md" ]; then
        # Existing symlink - check if it points to the right place
        if [ "$(readlink "$REPO_ROOT/codegen/PROJECT_CONTEXT.md")" != "$PROJECT_CONTEXT_DIR/PROJECT_CONTEXT.md" ]; then
            ln -sf "$PROJECT_CONTEXT_DIR/PROJECT_CONTEXT.md" "$REPO_ROOT/codegen/PROJECT_CONTEXT.md"
            echo "✅ Updated PROJECT_CONTEXT.md symlink to project context"
        else
            echo "ℹ️  PROJECT_CONTEXT.md symlink already points to project context"
        fi
    elif [ -f "$REPO_ROOT/codegen/PROJECT_CONTEXT.md" ]; then
        # Regular file exists - replace with symlink (no backup)
        rm "$REPO_ROOT/codegen/PROJECT_CONTEXT.md"
        ln -sf "$PROJECT_CONTEXT_DIR/PROJECT_CONTEXT.md" "$REPO_ROOT/codegen/PROJECT_CONTEXT.md"
        echo "✅ Replaced PROJECT_CONTEXT.md with symlink to project context"
    else
        # No file exists - create symlink
        ln -sf "$PROJECT_CONTEXT_DIR/PROJECT_CONTEXT.md" "$REPO_ROOT/codegen/PROJECT_CONTEXT.md"
        echo "✅ Created PROJECT_CONTEXT.md symlink to project context"
    fi
else
    # No project-specific PROJECT_CONTEXT.md, create from template in context first
    if [ ! -f "$REPO_ROOT/codegen/PROJECT_CONTEXT.md" ] && [ ! -L "$REPO_ROOT/codegen/PROJECT_CONTEXT.md" ]; then
        # Create project context directory if it doesn't exist
        mkdir -p "$PROJECT_CONTEXT_DIR"

        # Copy template to context directory
        cp "$SCRIPT_DIR/templates/PROJECT_CONTEXT.md" "$PROJECT_CONTEXT_DIR/PROJECT_CONTEXT.md"

        CURRENT_DATE=$(date +"%B %d, %Y")
        sed -i '' "s|{{CURRENT_DATE}}|$CURRENT_DATE|g" "$PROJECT_CONTEXT_DIR/PROJECT_CONTEXT.md"
        sed -i '' "s|{{PROJECT_NAME}}|$PROJECT_NAME|g" "$PROJECT_CONTEXT_DIR/PROJECT_CONTEXT.md"

        # Now create symlink to the context file
        ln -sf "$PROJECT_CONTEXT_DIR/PROJECT_CONTEXT.md" "$REPO_ROOT/codegen/PROJECT_CONTEXT.md"
        echo "✅ Created PROJECT_CONTEXT.md in context and symlinked to project"

        # We just created it from template, so we need AI to fill it
        NEEDS_AI_ANALYSIS=true
    else
        echo "ℹ️  PROJECT_CONTEXT.md already exists, skipping..."
    fi
fi

# Create symlinks to project-specific Figma files
FIGMA_FILES=("FIGMA_MAP.md" "FIGMA_DESIGN_SYSTEM_RULES.md" "FIGMA_TOKEN_MAPPING.md")

for figma_file in "${FIGMA_FILES[@]}"; do
    if [ -f "$PROJECT_CONTEXT_DIR/$figma_file" ]; then
        # Project-specific Figma file exists, create or update symlink
        if [ -L "$REPO_ROOT/codegen/$figma_file" ]; then
            # Existing symlink - check if it points to the right place
            if [ "$(readlink "$REPO_ROOT/codegen/$figma_file")" != "$PROJECT_CONTEXT_DIR/$figma_file" ]; then
                ln -sf "$PROJECT_CONTEXT_DIR/$figma_file" "$REPO_ROOT/codegen/$figma_file"
                echo "✅ Updated $figma_file symlink to project context"
            else
                echo "ℹ️  $figma_file symlink already points to project context"
            fi
        elif [ -f "$REPO_ROOT/codegen/$figma_file" ]; then
            # Regular file exists - replace with symlink (no backup)
            rm "$REPO_ROOT/codegen/$figma_file"
            ln -sf "$PROJECT_CONTEXT_DIR/$figma_file" "$REPO_ROOT/codegen/$figma_file"
            echo "✅ Replaced $figma_file with symlink to project context"
        else
            # No file exists - create symlink
            ln -sf "$PROJECT_CONTEXT_DIR/$figma_file" "$REPO_ROOT/codegen/$figma_file"
            echo "✅ Created $figma_file symlink to project context"
        fi
    else
        echo "ℹ️  $figma_file not available in project context"
    fi
done

# Create AGENTS.md - prefer project-specific context, fallback to template

if [ -d "$PROJECT_CONTEXT_DIR" ] && [ -f "$PROJECT_CONTEXT_DIR/AGENTS.md" ]; then
    # Project-specific AGENTS.md exists, create or update symlink
    if [ -L "$REPO_ROOT/AGENTS.md" ]; then
        # Existing symlink - check if it points to the right place
        if [ "$(readlink "$REPO_ROOT/AGENTS.md")" != "$PROJECT_CONTEXT_DIR/AGENTS.md" ]; then
            ln -sf "$PROJECT_CONTEXT_DIR/AGENTS.md" "$REPO_ROOT/AGENTS.md"
            echo "✅ Updated AGENTS.md symlink to project context"
        else
            echo "ℹ️  AGENTS.md symlink already points to project context"
        fi
    elif [ -f "$REPO_ROOT/AGENTS.md" ]; then
        # Regular file exists - replace with symlink (no backup)
        rm "$REPO_ROOT/AGENTS.md"
        ln -sf "$PROJECT_CONTEXT_DIR/AGENTS.md" "$REPO_ROOT/AGENTS.md"
        echo "✅ Replaced AGENTS.md with symlink to project context"
    else
        # No file exists - create symlink
        ln -sf "$PROJECT_CONTEXT_DIR/AGENTS.md" "$REPO_ROOT/AGENTS.md"
        echo "✅ Created AGENTS.md symlink to project context"
    fi
else
    # No project-specific AGENTS.md, use template if file doesn't exist
    if [ ! -f "$REPO_ROOT/AGENTS.md" ] && [ ! -L "$REPO_ROOT/AGENTS.md" ]; then
        cp "$SCRIPT_DIR/templates/AGENTS.md" "$REPO_ROOT/AGENTS.md"
        echo "✅ Created AGENTS.md from template (no project-specific version found)"
    else
        echo "ℹ️  AGENTS.md already exists, skipping..."
    fi
fi

# Create CLAUDE.md symlink for backward compatibility
if [ -L "$REPO_ROOT/CLAUDE.md" ]; then
    # Existing symlink - check if it points to AGENTS.md
    if [ "$(readlink "$REPO_ROOT/CLAUDE.md")" != "AGENTS.md" ]; then
        ln -sf "AGENTS.md" "$REPO_ROOT/CLAUDE.md"
        echo "✅ Updated CLAUDE.md symlink for backward compatibility"
    else
        echo "ℹ️  CLAUDE.md symlink already points to AGENTS.md"
    fi
elif [ -f "$REPO_ROOT/CLAUDE.md" ]; then
    # Regular file exists - replace with symlink (no backup)
    rm "$REPO_ROOT/CLAUDE.md"
    ln -sf "AGENTS.md" "$REPO_ROOT/CLAUDE.md"
    echo "✅ Replaced CLAUDE.md with symlink for backward compatibility"
else
    # No file exists - create symlink
    ln -sf "AGENTS.md" "$REPO_ROOT/CLAUDE.md"
    echo "✅ Created CLAUDE.md symlink for backward compatibility"
fi

# Create symbolic link to rules
if [ -d "$OCG_CONTEXT_DIR/rules" ]; then
    if [ -L "$REPO_ROOT/codegen/rules" ]; then
        # Existing symlink - check if it points to the right place
        if [ "$(readlink "$REPO_ROOT/codegen/rules")" != "$OCG_CONTEXT_DIR/rules" ]; then
            ln -sf "$OCG_CONTEXT_DIR/rules" "$REPO_ROOT/codegen/rules"
            echo "✅ Updated rules symlink to: $OCG_CONTEXT_DIR/rules"
        else
            echo "ℹ️  Rules symlink already points to correct location"
        fi
    elif [ -d "$REPO_ROOT/codegen/rules" ]; then
        # Regular directory exists - replace with symlink (no backup)
        rm -rf "$REPO_ROOT/codegen/rules"
        ln -sf "$OCG_CONTEXT_DIR/rules" "$REPO_ROOT/codegen/rules"
        echo "✅ Replaced rules directory with symlink to: $OCG_CONTEXT_DIR/rules"
    else
        # No file/directory exists - create symlink
        ln -sf "$OCG_CONTEXT_DIR/rules" "$REPO_ROOT/codegen/rules"
        echo "✅ Created symbolic link to development rules at: $OCG_CONTEXT_DIR/rules"
    fi
else
    echo "❌ ERROR: Rules directory not found at: $OCG_CONTEXT_DIR/rules"
    echo "   Please ensure the rules directory exists in your OCG_CONTEXT_DIR."
    exit 1
fi

# Create symbolic link to recipes
if [ -d "$OCG_CONTEXT_DIR/recipes" ]; then
    if [ -L "$REPO_ROOT/codegen/recipes" ]; then
        # Existing symlink - check if it points to the right place
        if [ "$(readlink "$REPO_ROOT/codegen/recipes")" != "$OCG_CONTEXT_DIR/recipes" ]; then
            ln -sf "$OCG_CONTEXT_DIR/recipes" "$REPO_ROOT/codegen/recipes"
            echo "✅ Updated recipes symlink to: $OCG_CONTEXT_DIR/recipes"
        else
            echo "ℹ️  Recipes symlink already points to correct location"
        fi
    elif [ -d "$REPO_ROOT/codegen/recipes" ]; then
        # Regular directory exists - replace with symlink (no backup)
        rm -rf "$REPO_ROOT/codegen/recipes"
        ln -sf "$OCG_CONTEXT_DIR/recipes" "$REPO_ROOT/codegen/recipes"
        echo "✅ Replaced recipes directory with symlink to: $OCG_CONTEXT_DIR/recipes"
    else
        # No file/directory exists - create symlink
        ln -sf "$OCG_CONTEXT_DIR/recipes" "$REPO_ROOT/codegen/recipes"
        echo "✅ Created symbolic link to development recipes at: $OCG_CONTEXT_DIR/recipes"
    fi
else
    echo "❌ ERROR: Recipes directory not found at: $OCG_CONTEXT_DIR/recipes"
    echo "   Please ensure the recipes directory exists in your OCG_CONTEXT_DIR."
    exit 1
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
echo "   - AGENTS.md (AI agent instructions)"
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

# Check if we need AI analysis
if [ "$NEEDS_AI_ANALYSIS" = true ]; then
    # Load AI agent configuration
    CONFIG_FILE="$HOME/.ocg/config.json"
    if [ -f "$CONFIG_FILE" ]; then
        AI_AGENT=$(jq -r '.default_agent // "claude"' "$CONFIG_FILE")
    else
        AI_AGENT="claude"
    fi

    echo "🤖 Starting $AI_AGENT with Opus model for setup..."

    cd "$REPO_ROOT"

    # Create temporary prompt file
    PROMPT_FILE=$(mktemp)
    trap "rm -f $PROMPT_FILE" EXIT
    echo "$SETUP_PROMPT" >"$PROMPT_FILE"

    # Run AI agent
    "$SCRIPT_DIR/ai-agents/run-ai.sh" "$AI_AGENT" "opus" "$PROMPT_FILE"
else
    echo ""
    echo "ℹ️  PROJECT_CONTEXT.md already exists, skipping AI analysis"
    echo "🎯 Project setup complete! You can create workspaces with: $OCG_CMD new <feature-name>"
fi
