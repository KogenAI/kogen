#!/bin/bash

# Optimum Codegen CLI Uninstallation Script
# This script removes the globally installed ocg commands

INSTALL_DIR="$HOME/.local/bin"
SYMLINK_NAME="ocg"

echo "🗑️  Uninstalling Optimum Codegen CLI..."

# Remove ocg symlink
SYMLINK_PATH="$INSTALL_DIR/$SYMLINK_NAME"
if [ -L "$SYMLINK_PATH" ] || [ -f "$SYMLINK_PATH" ]; then
    echo "   🔗 Removing $SYMLINK_NAME command"
    rm -f "$SYMLINK_PATH"
else
    echo "   ℹ️  $SYMLINK_NAME command not found"
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

# Uninstall Claude Code native binary
echo ""
echo "🤖 Claude Code uninstallation..."
if command -v claude >/dev/null 2>&1; then
    echo "   ⚠️  Do you want to uninstall Claude Code? [y/N]"
    read -r confirm_claude

    if [ "$confirm_claude" = "y" ] || [ "$confirm_claude" = "Y" ]; then
        # Find and remove Claude Code binary from common locations
        CLAUDE_REMOVED=false

        # Check common installation paths
        for claude_path in "$HOME/.local/bin/claude" "/usr/local/bin/claude" "$HOME/bin/claude"; do
            if [ -f "$claude_path" ]; then
                rm -f "$claude_path"
                echo "   ✅ Removed Claude Code binary: $claude_path"
                CLAUDE_REMOVED=true
            fi
        done

        if [ "$CLAUDE_REMOVED" = false ]; then
            # Try to find Claude binary location
            CLAUDE_LOCATION=$(command -v claude 2>/dev/null)
            if [ -n "$CLAUDE_LOCATION" ]; then
                rm -f "$CLAUDE_LOCATION"
                echo "   ✅ Removed Claude Code binary: $CLAUDE_LOCATION"
            else
                echo "   ⚠️  Could not locate Claude Code binary for removal"
            fi
        fi
    else
        echo "   ℹ️  Keeping Claude Code installed"
    fi
else
    echo "   ℹ️  Claude Code not found"
fi

# Claude Code configuration and data removal
echo ""
echo "🤖 Claude Code configuration and data..."
CLAUDE_SETTINGS_DIR="$HOME/.claude"

# Check for all Claude Code data locations
CLAUDE_DATA_FOUND=false
for claude_path in "$HOME/.claude" "$HOME/.config/claude-code" "$HOME/.local/state/claude" "$HOME/.local/share/claude" "$HOME/Library/Caches/claude-cli-nodejs"; do
    if [ -d "$claude_path" ]; then
        CLAUDE_DATA_FOUND=true
        break
    fi
done

if [ "$CLAUDE_DATA_FOUND" = "true" ]; then
    echo "   ⚙️  Found Claude Code data (configuration, settings, sessions, cache)"
    echo "   ⚠️  Do you want to remove ALL Claude Code data? [y/N]"
    echo "       This includes: settings, commands, sub agents, sessions, and cache"
    read -r confirm_claude_all

    if [ "$confirm_claude_all" = "y" ] || [ "$confirm_claude_all" = "Y" ]; then
        # Remove all Claude Code data locations
        for claude_data_path in "$HOME/.claude" "$HOME/.config/claude-code" "$HOME/.local/state/claude" "$HOME/.local/share/claude" "$HOME/Library/Caches/claude-cli-nodejs"; do
            if [ -d "$claude_data_path" ]; then
                rm -rf "$claude_data_path"
                echo "   ✅ Removed Claude Code data: $claude_data_path"
            fi
        done
    else
        echo "   ℹ️  Keeping Claude Code data"
    fi
else
    echo "   ℹ️  No Claude Code data found"
fi

# Uninstall Codex CLI
echo ""
echo "🤖 Codex CLI uninstallation..."
if command -v codex >/dev/null 2>&1; then
    echo "   ⚠️  Do you want to uninstall Codex CLI? [y/N]"
    read -r confirm_codex

    if [ "$confirm_codex" = "y" ] || [ "$confirm_codex" = "Y" ]; then
        npm uninstall -g @openai/codex 2>/dev/null || echo "   ⚠️  Could not uninstall via npm"
        # Remove Codex configuration
        if [ -d "$HOME/.codex" ]; then
            echo "   ⚠️  Do you want to remove Codex configuration (~/.codex)? [y/N]"
            read -r confirm_codex_config
            if [ "$confirm_codex_config" = "y" ] || [ "$confirm_codex_config" = "Y" ]; then
                rm -rf "$HOME/.codex"
                echo "   ✅ Removed Codex data: $HOME/.codex"
            fi
        fi
    else
        echo "   ℹ️  Keeping Codex installed"
    fi
else
    echo "   ℹ️  Codex CLI not found"
fi

echo ""
echo "✅ Uninstallation complete!"
echo ""
echo "💡 Note: This does not remove $INSTALL_DIR from your PATH"
echo "   If you no longer need it, you can manually remove it from your shell configuration"
echo ""
echo "💡 Restart your terminal or run 'source $RC_FILE' to apply changes"
