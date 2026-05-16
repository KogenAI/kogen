#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"
source "$SCRIPT_DIR/utils.sh"

# Parse command line arguments
MODEL_OVERRIDE=""
AGENT_OVERRIDE=""
UPDATE_MODE=false
while [[ $# -gt 0 ]]; do
    case $1 in
    --model | -m)
        MODEL_OVERRIDE="$2"
        shift 2
        ;;
    --agent | -a | --ai)
        AGENT_OVERRIDE="$2"
        shift 2
        ;;
    --update)
        UPDATE_MODE=true
        shift
        ;;
    --help | -h)
        echo "Usage: ocg setup [options]"
        echo "Options:"
        echo "  --model, -m <model>    AI model to use (haiku/sonnet/opus, default: opus)"
        echo "  --agent, -a <name>     AI agent to use (default: from config)"
        echo "  --update               Re-render AGENTS.md + CLAUDE.md from upstream template"
        echo "                         even when target files already exist."
        exit 0
        ;;
    *)
        echo "Unknown option: $1"
        exit 1
        ;;
    esac
done

REPO_ROOT="$TARGET_REPO_PATH"

echo "🚀 Setting up Optimum Codegen for project..."
echo "📁 Project: $REPO_ROOT"

mkdir -p "$REPO_ROOT/codegen"
mkdir -p "$REPO_ROOT/codegen/plans"
mkdir -p "$REPO_ROOT/codegen/contexts"
mkdir -p "$REPO_ROOT/context"

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

        # Detect if monorepo and use appropriate template
        TEMPLATE_FILE="$SCRIPT_DIR/templates/PROJECT_CONTEXT.md"
        if [ -f "$REPO_ROOT/backend/mix.exs" ] && [ -d "$REPO_ROOT/mobile" ]; then
            TEMPLATE_FILE="$SCRIPT_DIR/templates/PROJECT_CONTEXT-MONOREPO.md"
            echo "🔍 Detected monorepo structure, using monorepo template"
        fi

        # Copy template to context directory
        cp "$TEMPLATE_FILE" "$PROJECT_CONTEXT_DIR/PROJECT_CONTEXT.md"

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

# Create context/ directory with domain templates if new project
if [ "$NEEDS_AI_ANALYSIS" = true ]; then
    # Copy domain context templates
    if [ -d "$SCRIPT_DIR/templates/context" ]; then
        for tmpl in "$SCRIPT_DIR/templates/context/"*.md; do
            tmpl_name=$(basename "$tmpl")
            if [ ! -f "$REPO_ROOT/context/$tmpl_name" ]; then
                cp "$tmpl" "$REPO_ROOT/context/$tmpl_name"
                sed -i '' "s|{{PROJECT_NAME}}|$PROJECT_NAME|g" "$REPO_ROOT/context/$tmpl_name"
            fi
        done
        echo "✅ Created domain context templates in context/"
    fi
fi

# Create codegen/context symlink to ../context/
if [ -L "$REPO_ROOT/codegen/context" ]; then
    echo "ℹ️  codegen/context symlink already exists"
elif [ -d "$REPO_ROOT/codegen/context" ]; then
    # Regular directory exists — move contents to context/ and replace with symlink
    if [ "$(ls -A "$REPO_ROOT/codegen/context" 2>/dev/null)" ]; then
        mv "$REPO_ROOT/codegen/context/"* "$REPO_ROOT/context/" 2>/dev/null || true
    fi
    rmdir "$REPO_ROOT/codegen/context" 2>/dev/null || rm -rf "$REPO_ROOT/codegen/context"
    ln -s ../context "$REPO_ROOT/codegen/context"
    echo "✅ Replaced codegen/context/ directory with symlink to ../context/"
else
    ln -s ../context "$REPO_ROOT/codegen/context"
    echo "✅ Created codegen/context symlink to ../context/"
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

# Create AGENTS.md in project context directory, then symlink from project root

# Check if this is a POC project by looking for POC markers
IS_POC_PROJECT=false
if [ -f "$REPO_ROOT/.poc" ] || grep -q "POC Project" "$REPO_ROOT/README.md" 2>/dev/null; then
    IS_POC_PROJECT=true
fi

# Ensure project-specific AGENTS.md exists in context directory
if [ ! -f "$PROJECT_CONTEXT_DIR/AGENTS.md" ]; then
    mkdir -p "$PROJECT_CONTEXT_DIR"
    if [ "$IS_POC_PROJECT" = true ]; then
        cp "$SCRIPT_DIR/templates/AGENTS-POC.md" "$PROJECT_CONTEXT_DIR/AGENTS.md"
        echo "✅ Created project-specific AGENTS.md from POC template in context"
    else
        cp "$SCRIPT_DIR/templates/AGENTS.md" "$PROJECT_CONTEXT_DIR/AGENTS.md"
        echo "✅ Created project-specific AGENTS.md from template in context"
    fi
fi

# Render CLAUDE.md (claude, @-imports) and AGENTS.md (codex, → See pointers) as regular
# tracked files from the HYBRID template. Runs on every setup (not just --update).
# --update skips the cmp-s guard and forces re-render.
HYBRID_TEMPLATE="$SCRIPT_DIR/templates/AGENTS-HYBRID.md.j2"
PROCESS_TEMPLATE="$SCRIPT_DIR/templates/generator/process_template.py"

if [ ! -f "$HYBRID_TEMPLATE" ]; then
    echo "❌ ERROR: HYBRID template not found at: $HYBRID_TEMPLATE"
    exit 1
fi
if [ ! -f "$PROCESS_TEMPLATE" ]; then
    echo "❌ ERROR: process_template.py not found at: $PROCESS_TEMPLATE"
    exit 1
fi

echo ""
echo "🔄 Rendering CLAUDE.md + AGENTS.md from HYBRID template..."

render_hybrid() {
    local tool_name="$1"
    local dst="$2"
    local tmp
    tmp="$(mktemp)"
    if ! OCG_CONTEXT_DIR="$OCG_CONTEXT_DIR" python3 "$PROCESS_TEMPLATE" \
        "$HYBRID_TEMPLATE" "$tool_name" false >"$tmp"; then
        echo "❌ ERROR: failed to render $HYBRID_TEMPLATE (tool=$tool_name)"
        rm -f "$tmp"
        return 1
    fi
    # Remove any existing symlink or file before writing.
    if [ -L "$dst" ] || [ -f "$dst" ]; then
        rm -f "$dst"
    fi
    if [ "$UPDATE_MODE" = true ] || [ ! -f "$dst" ] || ! cmp -s "$tmp" "$dst"; then
        mv "$tmp" "$dst"
        echo "   ✅ Rendered $(basename "$dst") (tool=$tool_name)"
    else
        rm -f "$tmp"
        echo "   ✅ $(basename "$dst") already up to date"
    fi
}

render_hybrid claude "$REPO_ROOT/CLAUDE.md"
render_hybrid codex "$REPO_ROOT/AGENTS.md"

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

# Detect if this is a monorepo
IS_MONOREPO=false
if [ -f "$REPO_ROOT/backend/mix.exs" ] && [ -d "$REPO_ROOT/mobile" ]; then
    IS_MONOREPO=true
fi

if [ "$IS_MONOREPO" = true ]; then
    SETUP_PROMPT="# Monorepo Project Context Setup

I need you to analyze this **monorepo codebase** (backend + mobile) and fill out the project context files. This will serve as the foundational knowledge for all future AI development sessions.

## Context Structure

This project uses **split domain context**:
- \`./codegen/PROJECT_CONTEXT.md\` — concise index (~100 lines max). Overview, module directory, domain file loading guide.
- \`./context/*.md\` — domain-specific files with detailed context per business domain.

Two starter templates exist in \`./context/\`: \`core.md\` (primary business domain) and \`development.md\` (testing, CI, env vars, debugging).

## Your Task

1. **Fill out \`./codegen/PROJECT_CONTEXT.md\`** — replace placeholders. Keep concise — this is an index.
2. **Fill out \`./context/development.md\`** — tech stack, testing, env vars, deploy, pitfalls for BOTH backend and mobile.
3. **Fill out \`./context/core.md\`** — rename if better name fits. Document primary business domain.
4. **Create additional domain files** in \`./context/\` as needed:
   - Consider \`backend-api.md\` for Phoenix API endpoints and patterns
   - Consider \`mobile.md\` for Flutter architecture, screens, services
   - Consider domain-specific files (e.g., \`billing.md\`, \`notifications.md\`)
   - Each file is self-contained: modules, env vars, pitfalls for that domain
5. **Update the domain file table** in \`PROJECT_CONTEXT.md\` to list all created files.
6. **Create Figma files if needed** — only if evidence of Figma usage exists.

## Guidelines

- **Be specific, not generic** — use actual module names
- **Keep PROJECT_CONTEXT.md concise** — details go in domain files
- **Document mobile-backend integration** — how do they communicate?
- **Each domain file is self-contained** — its own modules, env vars, pitfalls

## Files to Analyze

**Backend** (\`./backend/\`): \`lib/*/\`, \`lib/*_web/\`, \`priv/repo/\`, \`config/\`, \`test/\`, \`mix.exs\`
**Mobile** (\`./mobile/\`): \`lib/\`, \`lib/screens/\`, \`lib/services/\`, \`lib/models/\`, \`test/\`, \`pubspec.yaml\`
**Common**: \`.tool-versions\`, \`Makefile\`, root and per-directory Makefiles

## Important Notes
$PROJECT_INFO

**Start by reviewing \`./codegen/PROJECT_CONTEXT.md\` and \`./context/*.md\` templates, then analyze BOTH directories.**"
else
    SETUP_PROMPT="# Project Context Setup

I need you to analyze this Phoenix/Elixir codebase and fill out the project context files. This will serve as the foundational knowledge for all future AI development sessions.

## Context Structure

This project uses **split domain context**:
- \`./codegen/PROJECT_CONTEXT.md\` — concise index (~100 lines max). Overview, module directory, domain file loading guide.
- \`./context/*.md\` — domain-specific files with detailed context per business domain.

Two starter templates exist in \`./context/\`: \`core.md\` (primary business domain) and \`development.md\` (testing, CI, env vars, debugging).

## Your Task

1. **Fill out \`./codegen/PROJECT_CONTEXT.md\`** — replace placeholders with real project details. Keep it concise — this is an index, not a dump.
2. **Fill out \`./context/development.md\`** — tech stack, testing strategy, env vars, deploy, pitfalls.
3. **Fill out \`./context/core.md\`** — rename if a better domain name fits (e.g., \`accounts.md\`, \`orders.md\`). Document the primary business domain.
4. **Create additional domain files** in \`./context/\` if the project has multiple distinct domains (e.g., \`billing.md\`, \`notifications.md\`). Each should be self-contained: modules, env vars, and pitfalls for that domain.
5. **Update the domain file table** in \`PROJECT_CONTEXT.md\` to list all created domain files with loading guidance.
6. **Create Figma files if needed** — only if evidence of Figma usage exists.

## Guidelines

- **Be specific, not generic** — use actual module names, not placeholders
- **Keep PROJECT_CONTEXT.md concise** — it's loaded on every session. Details go in domain files.
- **Each domain file is self-contained** — includes its own modules, env vars, and pitfalls
- **Focus on architecture** — how is the code organized and why?

## Files to Analyze

- \`lib/*/\` — Main application contexts
- \`lib/*_web/\` — Web layer (controllers, views, LiveViews)
- \`priv/repo/\` — Database migrations and seeds
- \`config/\` — Application configuration
- \`test/\` — Test patterns and structure
- \`.tool-versions\` — Runtime versions
- \`mix.exs\` — Dependencies and project configuration
- \`Dockerfile\` — Deployment configuration

## Important Notes
$PROJECT_INFO

**Start by reviewing \`./codegen/PROJECT_CONTEXT.md\` and \`./context/*.md\` templates, then analyze the codebase.**"
fi

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
*.code-workspace
.env"

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
echo "   - codegen/PROJECT_CONTEXT.md (concise project index)"
echo "   - context/*.md (domain-specific context files)"
echo "   - codegen/context/ (symlink to ../context/)"
echo "   - codegen/rules/ (symbolic link to development rules)"
echo "   - Updated .gitignore and .dockerignore"
echo ""
# Update config/dev.exs to support dynamic ports and database partitions
echo "🔧 Updating config/dev.exs for OCG compatibility..."

# Detect if this is a monorepo (has backend/ directory with mix.exs)
if [ -f "$REPO_ROOT/backend/mix.exs" ]; then
    DEV_CONFIG="$REPO_ROOT/backend/config/dev.exs"
    MIX_FILE="$REPO_ROOT/backend/mix.exs"
else
    DEV_CONFIG="$REPO_ROOT/config/dev.exs"
    MIX_FILE="$REPO_ROOT/mix.exs"
fi

if [ -f "$DEV_CONFIG" ]; then
    # Get app name from mix.exs
    APP_NAME=$(grep -E "app: :" "$MIX_FILE" | head -1 | sed -E 's/.*app: :([^,]+).*/\1/')

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

# Set up MCP integration (Tidewave)
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
        "$SCRIPT_DIR/templates/.mcp.json" >"$REPO_ROOT/.mcp.json"
    echo "✅ Created .mcp.json configuration"
fi

# Install dependencies if mix.exs was modified
if [ -f "$REPO_ROOT/mix.exs" ] && command -v mix >/dev/null 2>&1; then
    echo "📦 Installing dependencies..."
    cd "$REPO_ROOT"
    mix deps.get >/dev/null 2>&1
    echo "✅ Dependencies installed"
fi

# Check if we need AI analysis
if [ "$NEEDS_AI_ANALYSIS" = true ]; then
    # Load AI agent configuration
    CONFIG_FILE="$HOME/.ocg/config.json"
    if [ -n "$AGENT_OVERRIDE" ]; then
        case "$AGENT_OVERRIDE" in
        "claude" | "codex")
            AI_AGENT="$AGENT_OVERRIDE"
            ;;
        *)
            echo "⚠️  Invalid agent '$AGENT_OVERRIDE'. Valid agents: claude, codex"
            AI_AGENT=$(jq -r '.default_agent // "claude"' "$CONFIG_FILE" 2>/dev/null || echo "claude")
            ;;
        esac
    else
        if [ -f "$CONFIG_FILE" ]; then
            AI_AGENT=$(jq -r '.default_agent // "claude"' "$CONFIG_FILE")
        else
            AI_AGENT="claude"
        fi
    fi

    # Use model override if provided, otherwise default to opus
    if [ -n "$MODEL_OVERRIDE" ]; then
        case "$MODEL_OVERRIDE" in
        "haiku" | "sonnet" | "opus")
            MODEL="$MODEL_OVERRIDE"
            ;;
        *)
            echo "⚠️  Invalid model '$MODEL_OVERRIDE'. Valid models: haiku, sonnet, opus. Using default 'opus'"
            MODEL="opus"
            ;;
        esac
    else
        MODEL="opus"
    fi

    echo ""
    echo "🤖 Analyzing codebase and filling PROJECT_CONTEXT.md with $AI_AGENT ($MODEL)..."

    cd "$REPO_ROOT"

    # Use stdin piping with -p flag for autonomous tool execution
    echo "$SETUP_PROMPT" | claude --dangerously-skip-permissions --model "$MODEL" -p >/dev/null 2>&1

    echo "✅ PROJECT_CONTEXT.md filled by AI analysis"
else
    echo ""
    echo "ℹ️  PROJECT_CONTEXT.md already exists, skipping AI analysis"
fi

echo ""
echo "🎯 Project setup complete! You can create workspaces with: $OCG_CMD new <feature-name>"
