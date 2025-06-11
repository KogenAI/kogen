#!/bin/bash

# Optimum Codegen CLI Installation Script
# This script installs the ocg command globally

set -e

CODEGEN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$HOME/.local/bin"
SYMLINK_NAME="ocg"
ALT_SYMLINK_NAME="optimum_codegen"

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

# Create alternative symlink for optimum_codegen
ALT_SYMLINK_PATH="$INSTALL_DIR/$ALT_SYMLINK_NAME"
if [ -L "$ALT_SYMLINK_PATH" ] || [ -f "$ALT_SYMLINK_PATH" ]; then
    echo "   🔄 Removing existing $ALT_SYMLINK_NAME command"
    rm -f "$ALT_SYMLINK_PATH"
fi

echo "   🔗 Creating symlink: $ALT_SYMLINK_PATH -> $CODEGEN_DIR/ocg"
ln -s "$CODEGEN_DIR/ocg" "$ALT_SYMLINK_PATH"

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
echo "✅ Installation complete!"
echo ""
echo "🎯 You can now use these commands from anywhere:"
echo "   ocg new <feature-name>"
echo "   ocg batch"
echo "   ocg resume <feature-name>"
echo "   ocg rm <feature-name>"
echo "   ocg clean"
echo "   ocg ls"
echo "   ocg help"
echo ""
echo "   Or alternatively:"
echo "   optimum_codegen new <feature-name>"
echo "   optimum_codegen batch"
echo "   etc..."
echo ""
echo "💡 Restart your terminal or run 'source $RC_FILE' for autocompletion"
echo "💡 Test the installation by running: ocg help"
