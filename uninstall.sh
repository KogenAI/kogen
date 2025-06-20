#!/bin/bash

# Optimum Codegen CLI Uninstallation Script
# This script removes the globally installed ocg commands

INSTALL_DIR="$HOME/.local/bin"
SYMLINK_NAME="ocg"
ALT_SYMLINK_NAME="optimum_codegen"

echo "🗑️  Uninstalling Optimum Codegen CLI..."

# Remove ocg symlink
SYMLINK_PATH="$INSTALL_DIR/$SYMLINK_NAME"
if [ -L "$SYMLINK_PATH" ] || [ -f "$SYMLINK_PATH" ]; then
    echo "   🔗 Removing $SYMLINK_NAME command"
    rm -f "$SYMLINK_PATH"
else
    echo "   ℹ️  $SYMLINK_NAME command not found"
fi

# Remove optimum_codegen symlink
ALT_SYMLINK_PATH="$INSTALL_DIR/$ALT_SYMLINK_NAME"
if [ -L "$ALT_SYMLINK_PATH" ] || [ -f "$ALT_SYMLINK_PATH" ]; then
    echo "   🔗 Removing $ALT_SYMLINK_NAME command"
    rm -f "$ALT_SYMLINK_PATH"
else
    echo "   ℹ️  $ALT_SYMLINK_NAME command not found"
fi

# Remove autocompletion from shell configuration
echo "   🧹 Removing autocompletion setup..."

if [ "$SHELL" = "/bin/zsh" ] || [ "$SHELL" = "/usr/bin/zsh" ]; then
    RC_FILE="$HOME/.zshrc"
else
    RC_FILE="$HOME/.bashrc"
fi

if [ -f "$RC_FILE" ]; then
    # Get the current codegen directory to match the exact source line
    CODEGEN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    # Create a temporary file without the completion lines
    TEMP_FILE=$(mktemp)

    # Remove the completion lines (comment line and exact source line)
    grep -v "# Optimum Codegen autocompletion" "$RC_FILE" |
        grep -v "source \"$CODEGEN_DIR/bash_completion.sh\"" >"$TEMP_FILE"

    # Check if anything was actually removed
    if ! cmp -s "$RC_FILE" "$TEMP_FILE"; then
        mv "$TEMP_FILE" "$RC_FILE"
        echo "   ✅ Removed autocompletion from $RC_FILE"
    else
        rm -f "$TEMP_FILE"
        echo "   ℹ️  No autocompletion found in $RC_FILE"
    fi
else
    echo "   ℹ️  Shell configuration file $RC_FILE not found"
fi

CLAUDE_SETTINGS_FILE="$HOME/.claude/settings.json"

if [ -f "$CLAUDE_SETTINGS_FILE" ]; then
    echo "   ⚙️  Found Claude Code settings"
    echo "   ⚠️  Do you want to remove Claude Code settings? [y/N]"
    read -r confirm

    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        rm -f "$CLAUDE_SETTINGS_FILE"
        echo "   ✅ Removed Claude Code settings"
        rmdir "$HOME/.claude" 2>/dev/null || true
    else
        echo "   ℹ️  Keeping Claude Code settings"
    fi
else
    echo "   ℹ️  No Claude Code settings found"
fi

echo ""
echo "✅ Uninstallation complete!"
echo ""
echo "💡 Note: This does not remove $INSTALL_DIR from your PATH"
echo "   If you no longer need it, you can manually remove it from your shell configuration"
echo ""
echo "💡 Restart your terminal or run 'source $RC_FILE' to apply changes"
