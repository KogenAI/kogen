#!/bin/bash

# Optimum Codegen CLI Installation Script
# Usage: install.sh [--all]
#   By default installs Claude Code only.
#   Pass --all to also install OpenCode and Cursor CLI.
#
# Environment variables:
#   STACK — controls which subagent templates are installed (default: platform)
#     platform  — shared roles + phoenix-developer (combobulate machines)
#     phoenix   — shared roles + phoenix-developer (Phoenix user-app builds)
#     static    — shared roles + static-site-developer (static user-app builds)
#     all       — all roles (back-compat for non-stack-aware OCG projects)

set -e

INSTALL_ALL=false
for arg in "$@"; do
    [ "$arg" = "--all" ] && INSTALL_ALL=true
done

# Stack controls which subagent templates are rendered and installed.
# Default is "platform" so combobulate developer machines get the right set.
STACK="${STACK:-platform}"
export STACK

CODEGEN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$HOME/.local/bin"
SYMLINK_NAME="ocg"

echo "🚀 Installing Optimum Codegen CLI..."
echo "   📁 Codegen directory: $CODEGEN_DIR"
echo "   📁 Install directory: $INSTALL_DIR"

# Create install directory if it doesn't exist
if [ ! -d "$INSTALL_DIR" ]; then
    echo "   📁 Creating install directory: $INSTALL_DIR"
    mkdir -p "$INSTALL_DIR"
fi

# Create symlink for ocg
SYMLINK_PATH="$INSTALL_DIR/$SYMLINK_NAME"
if [ -L "$SYMLINK_PATH" ] || [ -f "$SYMLINK_PATH" ]; then
    echo "   🔄 Removing existing $SYMLINK_NAME command"
    rm -f "$SYMLINK_PATH"
fi

echo "   🔗 Creating symlink: $SYMLINK_PATH -> $CODEGEN_DIR/ocg"
ln -s "$CODEGEN_DIR/ocg" "$SYMLINK_PATH"

# Check if ~/.local/bin is in PATH
if [[ ":$PATH:" != *":$INSTALL_DIR:"* ]]; then
    echo ""
    echo "⚠️  $INSTALL_DIR is not in your PATH"
    echo "   Add this line to your shell configuration file:"

    if [ "$SHELL" = "/bin/zsh" ] || [ "$SHELL" = "/usr/bin/zsh" ]; then
        RC_FILE="$HOME/.zshrc"
        echo "   echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> $RC_FILE"
    else
        RC_FILE="$HOME/.bashrc"
        echo "   echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> $RC_FILE"
    fi

    echo ""
    echo "   Or run this command to add it automatically:"
    echo "   echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> $RC_FILE"
    echo ""
    echo "   Then restart your terminal or run: source $RC_FILE"
else
    echo "   ✅ $INSTALL_DIR is already in your PATH"
fi

echo ""
echo "🚀 Setting up context repository..."

# Clone context repository if it doesn't exist
CONTEXT_DIR="${OCG_CONTEXT_DIR:-$HOME/Areas/Optimum/context}"

if [ ! -d "$CONTEXT_DIR" ]; then
    echo "   📥 Cloning context repository to: $CONTEXT_DIR"
    mkdir -p "$CONTEXT_DIR"
    git clone git@github.com:Combobulate-HQ/context.git "$CONTEXT_DIR"
    echo "   ✅ Context repository cloned successfully"
else
    echo "   ✅ Context repository already exists: $CONTEXT_DIR"
fi

echo ""
echo "🚀 Setting up recipes directory..."

RECIPES_DIR="${OCG_CONTEXT_DIR:-$HOME/Areas/Optimum/context}/recipes"
if [ ! -d "$RECIPES_DIR" ]; then
    echo "   📚 Creating recipes directory at: $RECIPES_DIR"
    mkdir -p "$RECIPES_DIR"
else
    echo "   ✅ Recipes directory already exists: $RECIPES_DIR"
fi

# Copy README only if it doesn't exist
if [ ! -f "$RECIPES_DIR/README.md" ] && [ -f "$CODEGEN_DIR/templates/recipes-README.md" ]; then
    cp "$CODEGEN_DIR/templates/recipes-README.md" "$RECIPES_DIR/README.md"
    echo "   ✅ Recipes README installed"
fi

echo ""
echo "🚀 Generating AI agent templates..."

# Generate templates — claude only by default, all tools with --all
if [ "$INSTALL_ALL" = true ]; then
    "$CODEGEN_DIR/templates/generator/generate.sh" all
else
    "$CODEGEN_DIR/templates/generator/generate.sh" claude
fi

# Clean up generated templates after installation
cleanup_generated_templates() {
    echo "   🧹 Cleaning up generated templates..."
    rm -rf "$CODEGEN_DIR/templates/generated/"
    echo "   ✅ Generated templates cleaned up"
}

echo ""
echo "🚀 Setting up Claude Code configuration..."

CLAUDE_SETTINGS_DIR="$HOME/.claude"
CLAUDE_SETTINGS_FILE="$CLAUDE_SETTINGS_DIR/settings.json"
CLAUDE_COMMANDS_DIR="$CLAUDE_SETTINGS_DIR/commands"

mkdir -p "$CLAUDE_SETTINGS_DIR"
mkdir -p "$CLAUDE_COMMANDS_DIR"

# Install generated Claude Code files
if [ -f "$CODEGEN_DIR/templates/generated/claude-code/claude-code-settings.json" ]; then
    cp "$CODEGEN_DIR/templates/generated/claude-code/claude-code-settings.json" "$CLAUDE_SETTINGS_FILE"
    echo "   ✅ Claude Code settings installed at: $CLAUDE_SETTINGS_FILE"
fi

echo ""
echo "🚀 Setting up Claude Code hooks..."

# Install Claude Code hooks
if [ -d "$CODEGEN_DIR/templates/shared/hooks" ]; then
    mkdir -p "$CLAUDE_SETTINGS_DIR/hooks"
    for hook_file in "$CODEGEN_DIR/templates/shared/hooks"/*.sh; do
        if [ -f "$hook_file" ]; then
            hook_name=$(basename "$hook_file")
            cp "$hook_file" "$CLAUDE_SETTINGS_DIR/hooks/$hook_name"
            chmod +x "$CLAUDE_SETTINGS_DIR/hooks/$hook_name"
            echo "   ✅ ${hook_name} hook installed at: $CLAUDE_SETTINGS_DIR/hooks/$hook_name"
        fi
    done
fi

# Install custom Claude commands
echo "   📁 Installing custom Claude commands..."

COMMANDS_MANIFEST="$CLAUDE_COMMANDS_DIR/.installed-by-ocg"
CURRENT_COMMANDS=()

# Copy plain .md commands directly from shared templates
if [ -d "$CODEGEN_DIR/templates/shared/commands" ]; then
    for cmd_file in "$CODEGEN_DIR/templates/shared/commands"/*.md; do
        if [ -f "$cmd_file" ]; then
            cmd_name=$(basename "$cmd_file")
            cp "$cmd_file" "$CLAUDE_COMMANDS_DIR/"
            echo "   ✅ Installed command: /${cmd_name%.md}"
            CURRENT_COMMANDS+=("$cmd_name")
        fi
    done
fi

# Delete stale commands (in previous manifest but not current set)
if [ -f "$COMMANDS_MANIFEST" ]; then
    while IFS= read -r old_cmd; do
        if [ -n "$old_cmd" ]; then
            still_present=false
            for cur in "${CURRENT_COMMANDS[@]}"; do
                [ "$cur" = "$old_cmd" ] && still_present=true && break
            done
            if [ "$still_present" = "false" ] && [ -f "$CLAUDE_COMMANDS_DIR/$old_cmd" ]; then
                rm -f "$CLAUDE_COMMANDS_DIR/$old_cmd"
                echo "   🗑️  Removed stale command: /${old_cmd%.md}"
            fi
        fi
    done <"$COMMANDS_MANIFEST"
fi

# Write manifest
printf '%s\n' "${CURRENT_COMMANDS[@]}" >"$COMMANDS_MANIFEST"

# Install Claude sub agents from generated templates
echo "   🤖 Installing Claude sub agents..."
CLAUDE_AGENTS_DIR="$CLAUDE_SETTINGS_DIR/agents"
mkdir -p "$CLAUDE_AGENTS_DIR"

AGENTS_MANIFEST="$CLAUDE_AGENTS_DIR/.installed-by-ocg"
CURRENT_AGENTS=()

if [ -d "$CODEGEN_DIR/templates/generated/claude-code/agents" ]; then
    for agent_file in "$CODEGEN_DIR/templates/generated/claude-code/agents"/*.md; do
        if [ -f "$agent_file" ]; then
            agent_name=$(basename "$agent_file")
            cp "$agent_file" "$CLAUDE_AGENTS_DIR/"
            echo "   ✅ Installed Claude sub agent: ${agent_name%.md}"
            CURRENT_AGENTS+=("$agent_name")
        fi
    done
fi

# Delete stale agents (in previous manifest but not current set)
if [ -f "$AGENTS_MANIFEST" ]; then
    while IFS= read -r old_agent; do
        if [ -n "$old_agent" ]; then
            still_present=false
            for cur in "${CURRENT_AGENTS[@]}"; do
                [ "$cur" = "$old_agent" ] && still_present=true && break
            done
            if [ "$still_present" = "false" ] && [ -f "$CLAUDE_AGENTS_DIR/$old_agent" ]; then
                rm -f "$CLAUDE_AGENTS_DIR/$old_agent"
                echo "   🗑️  Removed stale agent: ${old_agent%.md}"
            fi
        fi
    done <"$AGENTS_MANIFEST"
fi

# Write manifest
printf '%s\n' "${CURRENT_AGENTS[@]}" >"$AGENTS_MANIFEST"

# Install required dependencies
echo ""
echo "🚀 Installing required dependencies..."

# Install jq for JSON processing
if ! command -v jq >/dev/null 2>&1; then
    echo "   📦 Installing jq with brew..."
    if command -v brew >/dev/null 2>&1; then
        brew install jq
        echo "   ✅ jq installed"
    else
        echo "   ❌ Homebrew not found. Please install jq manually:"
        echo "      brew install jq"
        exit 1
    fi
else
    echo "   ✅ jq already installed"
fi

# Install system ripgrep for Claude Code custom command discovery
echo "   📦 Installing system ripgrep for Claude Code custom commands..."
if ! command -v rg >/dev/null 2>&1; then
    if command -v brew >/dev/null 2>&1; then
        brew install ripgrep
        echo "   ✅ System ripgrep installed"
    else
        echo "   ❌ Homebrew not found. Please install ripgrep manually:"
        echo "      brew install ripgrep"
        echo "   ⚠️  Custom Claude Code commands may not work without system ripgrep"
    fi
else
    echo "   ✅ System ripgrep already installed"
fi

# Set up OCG_CONTEXT_DIR environment variable
echo ""
echo "🚀 Setting up OCG_CONTEXT_DIR environment variable..."

CONTEXT_DIR_VAR="export OCG_CONTEXT_DIR=\"$HOME/Areas/Optimum/context\""

if [ "$SHELL" = "/bin/zsh" ] || [ "$SHELL" = "/usr/bin/zsh" ]; then
    RC_FILE="$HOME/.zshrc"
else
    RC_FILE="$HOME/.bashrc"
fi

if grep -q "OCG_CONTEXT_DIR" "$RC_FILE" 2>/dev/null; then
    echo "   ✅ OCG_CONTEXT_DIR already set in $RC_FILE"
else
    echo "" >>"$RC_FILE"
    echo "# Optimum Codegen context directory" >>"$RC_FILE"
    echo "$CONTEXT_DIR_VAR" >>"$RC_FILE"
    echo "   ✅ Added OCG_CONTEXT_DIR to $RC_FILE"
fi

# Set up USE_BUILTIN_RIPGREP=0 for Claude Code custom command discovery
echo ""
echo "🚀 Setting up Claude Code custom command support..."

RIPGREP_VAR="export USE_BUILTIN_RIPGREP=0"

if grep -q "USE_BUILTIN_RIPGREP" "$RC_FILE" 2>/dev/null; then
    echo "   ✅ USE_BUILTIN_RIPGREP already set in $RC_FILE"
else
    echo "" >>"$RC_FILE"
    echo "# Claude Code custom command discovery (requires system ripgrep)" >>"$RC_FILE"
    echo "$RIPGREP_VAR" >>"$RC_FILE"
    echo "   ✅ Added USE_BUILTIN_RIPGREP=0 to $RC_FILE"
fi

# Set up autocompletion
echo ""
echo "🚀 Setting up autocompletion..."

if [ "$SHELL" = "/bin/zsh" ] || [ "$SHELL" = "/usr/bin/zsh" ]; then
    RC_FILE="$HOME/.zshrc"
else
    RC_FILE="$HOME/.bashrc"
fi

if grep -q "bash_completion.sh" "$RC_FILE" 2>/dev/null; then
    echo "   ⚠️  Completion already appears to be set up in $RC_FILE"
else
    echo "" >>"$RC_FILE"
    echo "# Optimum Codegen autocompletion" >>"$RC_FILE"
    echo "source \"$CODEGEN_DIR/bash_completion.sh\"" >>"$RC_FILE"
    echo "   ✅ Added autocompletion to $RC_FILE"
fi

echo ""
echo "🚀 Setting up Claude Code bash environment..."

# Install Claude Code using the official curl installer (2025 method)
echo "🤖 Installing Claude Code..."
# Refresh command cache to detect recent removals
hash -r 2>/dev/null || true
if command -v claude >/dev/null 2>&1; then
    echo "   ✅ Claude Code already installed"
else
    curl -fsSL https://claude.ai/install.sh | bash
    echo "   ✅ Claude Code installed"
fi

if [ "$INSTALL_ALL" = true ]; then
    echo ""
    echo "🔧 Setting up OpenCode configuration..."

    mkdir -p "$HOME/.config/opencode"

    if [ -f "$CODEGEN_DIR/templates/generated/opencode/.opencode.json" ]; then
        cp "$CODEGEN_DIR/templates/generated/opencode/.opencode.json" "$HOME/.config/opencode/config.json"
        echo "   ✅ OpenCode configuration installed"
    fi

    if [ -f "$CODEGEN_DIR/templates/generated/opencode/AGENTS.md" ]; then
        cp "$CODEGEN_DIR/templates/generated/opencode/AGENTS.md" "$HOME/.config/opencode/"
        echo "   ✅ OpenCode AGENTS.md installed"
    fi

    echo "   🤖 Installing OpenCode sub agents..."
    OPENCODE_AGENTS_DIR="$HOME/.config/opencode/agent"
    mkdir -p "$OPENCODE_AGENTS_DIR"

    if [ -d "$CODEGEN_DIR/templates/generated/opencode/agent" ]; then
        for agent_file in "$CODEGEN_DIR/templates/generated/opencode/agent"/*.md; do
            if [ -f "$agent_file" ]; then
                agent_name=$(basename "$agent_file")
                cp "$agent_file" "$OPENCODE_AGENTS_DIR/"
                echo "   ✅ Installed OpenCode sub agent: ${agent_name%.md}"
            fi
        done
    fi

    echo "   📁 Installing OpenCode custom commands..."
    OPENCODE_COMMANDS_DIR="$HOME/.config/opencode/command"
    mkdir -p "$OPENCODE_COMMANDS_DIR"

    if [ -d "$CODEGEN_DIR/templates/shared/commands" ]; then
        for cmd_file in "$CODEGEN_DIR/templates/shared/commands"/*.md; do
            if [ -f "$cmd_file" ]; then
                cmd_name=$(basename "$cmd_file")
                cp "$cmd_file" "$OPENCODE_COMMANDS_DIR/"
                echo "   ✅ Installed OpenCode command: /${cmd_name%.md}"
            fi
        done
    fi

    echo ""
    echo "🔧 Setting up Cursor CLI configuration..."

    mkdir -p "$HOME/.cursor"

    echo "   📁 Installing Cursor CLI custom commands..."
    CURSOR_COMMANDS_DIR="$HOME/.cursor/commands"
    mkdir -p "$CURSOR_COMMANDS_DIR"

    if [ -d "$CODEGEN_DIR/templates/shared/commands" ]; then
        for cmd_file in "$CODEGEN_DIR/templates/shared/commands"/*.md; do
            if [ -f "$cmd_file" ]; then
                cmd_name=$(basename "$cmd_file")
                cp "$cmd_file" "$CURSOR_COMMANDS_DIR/"
                echo "   ✅ Installed Cursor command: /${cmd_name%.md}"
            fi
        done
    fi

    echo "   🤖 Installing Cursor CLI sub agents..."
    CURSOR_SUBAGENTS_DIR="$HOME/.cursor/subagents"
    mkdir -p "$CURSOR_SUBAGENTS_DIR"

    if [ -d "$CODEGEN_DIR/templates/generated/cursor/subagents" ]; then
        for agent_file in "$CODEGEN_DIR/templates/generated/cursor/subagents"/*.md; do
            if [ -f "$agent_file" ]; then
                agent_name=$(basename "$agent_file")
                cp "$agent_file" "$CURSOR_SUBAGENTS_DIR/"
                echo "   ✅ Installed Cursor sub agent: ${agent_name%.md}"
            fi
        done
    fi
fi

# Create OCG config directory
mkdir -p "$HOME/.ocg"

if [ ! -f "$HOME/.ocg/config.json" ]; then
    if [ "$INSTALL_ALL" = true ]; then
        echo ""
        echo "🤖 AI Agent Configuration"
        echo "   Claude Code, OpenCode, and Cursor CLI are now installed."
        echo "   Which should be your default AI agent?"
        echo "   1) claude (Claude Code)"
        echo "   2) opencode (OpenCode)"
        echo "   3) cursor (Cursor CLI)"
        echo ""
        read -p "   Choose [1-3]: " choice

        case $choice in
        1) default_agent="claude" ;;
        2) default_agent="opencode" ;;
        3) default_agent="cursor" ;;
        *) default_agent="claude" ;;
        esac
    else
        default_agent="claude"
    fi

    cat >"$HOME/.ocg/config.json" <<EOF
{
    "default_agent": "$default_agent",
    "agents": {
        "claude": { "enabled": true },
        "opencode": { "enabled": false, "provider": "anthropic" },
        "cursor": { "enabled": false }
    }
}
EOF
    echo "✅ Default AI agent set to: $default_agent"
else
    echo ""
    echo "✅ AI agent configuration already exists"
fi

# Clean up generated templates now that everything is installed
cleanup_generated_templates

echo ""
echo "✅ Installation complete!"
echo ""
echo "🎯 You can now use these commands from anywhere:"
echo "   ocg new <feature-name>"
echo "   ocg resume <feature-name>"
echo "   ocg rm <feature-name>"
echo "   ocg clean"
echo "   ocg ls"
echo "   ocg help"
echo ""
echo "💡 Restart your terminal or run 'source $RC_FILE' for autocompletion and Claude Code custom commands"
echo "💡 Test the installation by running: ocg help"
echo "💡 Test Claude Code custom commands by running: claude (then try /write-drop)"
echo "💡 Next: Run 'ocg setup' in your project directory to install project-specific tools"
