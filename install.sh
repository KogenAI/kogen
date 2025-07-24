#!/bin/bash

# Optimum Codegen CLI Installation Script
# This script installs the ocg command globally

set -e

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
echo "🚀 Setting up recipes directory..."

RECIPES_DIR="$HOME/Areas/Optimum/context/recipes"
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
echo "🚀 Setting up Claude Code configuration..."

CLAUDE_SETTINGS_DIR="$HOME/.claude"
CLAUDE_SETTINGS_FILE="$CLAUDE_SETTINGS_DIR/settings.json"
CLAUDE_COMMANDS_DIR="$CLAUDE_SETTINGS_DIR/commands"

mkdir -p "$CLAUDE_SETTINGS_DIR"
mkdir -p "$CLAUDE_COMMANDS_DIR"
cp "$CODEGEN_DIR/templates/claude-code-settings.json" "$CLAUDE_SETTINGS_FILE"
echo "   ✅ Claude Code settings installed at: $CLAUDE_SETTINGS_FILE"

# Install custom Claude commands from templates
echo "   📁 Installing custom Claude commands..."
if [ -d "$CODEGEN_DIR/templates/claude-commands" ]; then
    for cmd_file in "$CODEGEN_DIR/templates/claude-commands"/*.md; do
        if [ -f "$cmd_file" ]; then
            cmd_name=$(basename "$cmd_file")
            cp "$cmd_file" "$CLAUDE_COMMANDS_DIR/"
            echo "   ✅ Installed command: /${cmd_name%.md}"
        fi
    done
else
    echo "   ⚠️  No custom commands found in templates/claude-commands/"
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
if command -v claude >/dev/null 2>&1; then
    echo "   ✅ Claude Code already installed"
else
    curl -fsSL https://claude.ai/install.sh | bash
    echo "   ✅ Claude Code installed"
fi

echo ""
echo "🤖 Installing OpenCode..."
# Install OpenCode alongside Claude Code
if command -v opencode >/dev/null 2>&1; then
    echo "   ✅ OpenCode already installed"
else
    curl -fsSL https://opencode.ai/install | bash
    echo "   ✅ OpenCode installed"
fi

echo ""
echo "🔧 Setting up OpenCode configuration..."
# Create OpenCode config directory if it doesn't exist
mkdir -p "$HOME/.config/opencode"

# Basic OpenCode config for OCG integration
if [ ! -f "$HOME/.config/opencode/config.json" ]; then
    cat >"$HOME/.config/opencode/config.json" <<EOF
{
    "default_provider": "anthropic",
    "mcp": {
        "enabled": true
    }
}
EOF
    echo "   ✅ OpenCode configuration set up"
else
    echo "   ✅ OpenCode configuration already exists"
fi

# Create OCG config directory
mkdir -p "$HOME/.ocg"

# AI Assistant Configuration - both are now installed
if [ ! -f "$HOME/.ocg/config.json" ]; then
    echo ""
    echo "🤖 AI Assistant Configuration"
    echo "   Both Claude Code and OpenCode are now installed."
    echo "   Which should be your default AI assistant?"
    echo "   1) claude (Claude Code)"
    echo "   2) opencode (OpenCode)"
    echo ""
    read -p "   Choose [1-2]: " choice

    case $choice in
    1)
        default_assistant="claude"
        ;;
    2)
        default_assistant="opencode"
        ;;
    *)
        echo "❌ Invalid choice. Defaulting to claude."
        default_assistant="claude"
        ;;
    esac

    # Create initial config with both assistants enabled
    cat >"$HOME/.ocg/config.json" <<EOF
{
    "default_assistant": "$default_assistant",
    "assistants": {
        "claude": {
            "enabled": true
        },
        "opencode": {
            "enabled": true,
            "provider": "anthropic"
        }
    }
}
EOF

    echo "✅ Default AI assistant set to: $default_assistant"
    echo ""
    echo "💡 You can switch between assistants anytime with: ocg ai-config set default [claude|opencode]"
    echo "💡 Or override per-command with: ocg new feature --assistant [claude|opencode]"
else
    echo ""
    echo "✅ AI assistant configuration already exists"
fi

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
echo "💡 Restart your terminal or run 'source $RC_FILE' for autocompletion"
echo "💡 Test the installation by running: ocg help"
echo "💡 Next: Run 'ocg setup' in your project directory to install project-specific tools"
