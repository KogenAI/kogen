#!/bin/bash

# Optimum Codegen CLI Uninstallation Script
# This script removes the globally installed ocg commands

CODEGEN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$HOME/.local/bin"
SYMLINK_NAME="ocg"
CODEGEN_LOG_NAME="codegen-log"

# Source manifest-lib for manifest_launchers / manifest_completions
# shellcheck source=templates/generator/manifest-lib.sh
source "$CODEGEN_DIR/templates/generator/manifest-lib.sh" 2>/dev/null || true

echo "🗑️  Uninstalling Optimum Codegen CLI..."

# Remove ocg symlink
SYMLINK_PATH="$INSTALL_DIR/$SYMLINK_NAME"
if [ -L "$SYMLINK_PATH" ] || [ -f "$SYMLINK_PATH" ]; then
    echo "   🔗 Removing $SYMLINK_NAME command"
    rm -f "$SYMLINK_PATH"
else
    echo "   ℹ️  $SYMLINK_NAME command not found"
fi

# Remove codegen-log symlink
CODEGEN_LOG_PATH="$INSTALL_DIR/$CODEGEN_LOG_NAME"
if [ -L "$CODEGEN_LOG_PATH" ] || [ -f "$CODEGEN_LOG_PATH" ]; then
    echo "   🔗 Removing $CODEGEN_LOG_NAME command"
    rm -f "$CODEGEN_LOG_PATH"
else
    echo "   ℹ️  $CODEGEN_LOG_NAME command not found"
fi

# Remove dispatch-path sibling symlinks (harnesses/shared/templates/analysis)
# planted by install.sh so installed launcher COPIES can resolve outside
# harnesses/ and shared/.
for _sib in harnesses shared templates analysis; do
    _sib_path="$INSTALL_DIR/$_sib"
    if [ -L "$_sib_path" ]; then
        echo "   🔗 Removing $_sib symlink"
        rm -f "$_sib_path"
    fi
done

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
    if [[ -t 0 ]]; then
        read -r confirm_claude
    else
        echo "   ℹ️  non-interactive (no TTY): keeping Claude Code installed"
        confirm_claude=N
    fi

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
    if [[ -t 0 ]]; then
        read -r confirm_claude_all
    else
        echo "   ℹ️  non-interactive (no TTY): keeping Claude Code data"
        confirm_claude_all=N
    fi

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

# ── Legacy cleanup: Pi + codex launchers ─────────────────────────────────────
# Both harnesses were removed from source and are in no manifest, so nothing
# here can be manifest-driven — these are hardcoded known names, cleaning up
# what earlier installs of this repo put on disk.
echo ""
echo "🧹 Removing legacy launchers and data..."

for _legacy in pi-build pi-debug pi-shape pi-ops pi-experiment \
    codex-build codex-inspector codex-refactor codex-shape; do
    if [ -f "$INSTALL_DIR/$_legacy" ]; then
        rm -f "$INSTALL_DIR/$_legacy"
        echo "   ✅ Removed legacy launcher: $_legacy"
    fi
done

# Override search list via env: ZSH_COMPLETION_DIRS="/path1:/path2" (colon-separated, same toggle as install.sh).
IFS=':' read -ra _ZSH_COMPLETION_DIRS <<<"${ZSH_COMPLETION_DIRS:-/usr/local/share/zsh/site-functions:$HOME/.zsh/completions:$HOME/.local/share/zsh/site-functions}"
for _comp in _pi-build _pi-debug _pi-shape _pi-ops; do
    for _dir in "${_ZSH_COMPLETION_DIRS[@]}"; do
        if [ -f "$_dir/$_comp" ]; then
            rm -f "$_dir/$_comp"
            echo "   ✅ Removed legacy zsh completion: $_comp from $_dir"
        fi
    done
done

for _legacy_dir in "$HOME/.pi/agent/agents" "$HOME/.pi/agent/prompts"; do
    if [ -d "$_legacy_dir" ]; then
        _count=0
        for _f in "$_legacy_dir"/*.md; do
            [ -f "$_f" ] || continue
            rm -f "$_f"
            _count=$((_count + 1))
        done
        [ "$_count" -gt 0 ] && echo "   ✅ Removed $_count legacy file(s) from $_legacy_dir"
    fi
done

echo ""
echo "✅ Uninstallation complete!"
echo ""
echo "💡 Note: This does not remove $INSTALL_DIR from your PATH"
echo "   If you no longer need it, you can manually remove it from your shell configuration"
echo ""
echo "💡 Restart your terminal or run 'source $RC_FILE' to apply changes"
