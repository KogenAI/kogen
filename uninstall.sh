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

# Uninstall OpenCode native binary
echo ""
echo "🤖 OpenCode uninstallation..."
if command -v opencode >/dev/null 2>&1; then
    echo "   ⚠️  Do you want to uninstall OpenCode? [y/N]"
    read -r confirm_opencode

    if [ "$confirm_opencode" = "y" ] || [ "$confirm_opencode" = "Y" ]; then
        # Find and remove OpenCode binary from common locations
        OPENCODE_REMOVED=false

        # Check OpenCode installation paths (based on install script priority)
        for opencode_path in "$OPENCODE_INSTALL_DIR/opencode" "$XDG_BIN_DIR/opencode" "$HOME/bin/opencode" "$HOME/.opencode/bin/opencode" "$HOME/.local/bin/opencode" "/usr/local/bin/opencode"; do
            if [ -f "$opencode_path" ]; then
                rm -f "$opencode_path"
                echo "   ✅ Removed OpenCode binary: $opencode_path"
                OPENCODE_REMOVED=true
            fi
        done

        if [ "$OPENCODE_REMOVED" = false ]; then
            # Try to find OpenCode binary location
            OPENCODE_LOCATION=$(command -v opencode 2>/dev/null)
            if [ -n "$OPENCODE_LOCATION" ]; then
                rm -f "$OPENCODE_LOCATION"
                echo "   ✅ Removed OpenCode binary: $OPENCODE_LOCATION"
            else
                echo "   ⚠️  Could not locate OpenCode binary for removal"
            fi
        fi

        # Remove OpenCode configuration and session data
        OPENCODE_CLEANUP=false
        for opencode_data_path in "$HOME/.config/opencode" "$HOME/.local/state/opencode" "$HOME/.local/share/opencode" "$HOME/.cache/opencode"; do
            if [ -d "$opencode_data_path" ]; then
                OPENCODE_CLEANUP=true
                break
            fi
        done

        if [ "$OPENCODE_CLEANUP" = "true" ]; then
            echo "   ⚠️  Do you want to remove OpenCode configuration and session data? [y/N]"
            read -r confirm_opencode_config
            if [ "$confirm_opencode_config" = "y" ] || [ "$confirm_opencode_config" = "Y" ]; then
                for opencode_data_path in "$HOME/.config/opencode" "$HOME/.local/state/opencode" "$HOME/.local/share/opencode" "$HOME/.cache/opencode"; do
                    if [ -d "$opencode_data_path" ]; then
                        rm -rf "$opencode_data_path"
                        echo "   ✅ Removed OpenCode data: $opencode_data_path"
                    fi
                done
            fi
        fi

        # Remove OpenCode binary directory if it exists and is empty
        if [ -d "$HOME/.opencode/bin" ]; then
            rmdir "$HOME/.opencode/bin" 2>/dev/null || true
            rmdir "$HOME/.opencode" 2>/dev/null || true
        fi
    else
        echo "   ℹ️  Keeping OpenCode installed"
    fi
else
    echo "   ℹ️  OpenCode not found"
fi

echo ""
echo "✅ Uninstallation complete!"
echo ""
echo "💡 Note: This does not remove $INSTALL_DIR from your PATH"
echo "   If you no longer need it, you can manually remove it from your shell configuration"
echo ""
echo "💡 Restart your terminal or run 'source $RC_FILE' to apply changes"
