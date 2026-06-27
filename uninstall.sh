#!/bin/bash

# Optimum Codegen CLI Uninstallation Script
# This script removes the globally installed ocg commands

CODEGEN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$HOME/.local/bin"
SYMLINK_NAME="ocg"

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

# ── Pi uninstall ──────────────────────────────────────────────────────────────
echo ""
echo "🤖 Pi uninstallation..."

# Remove pi launchers
if command -v manifest_launchers >/dev/null 2>&1 && [ -f "$CODEGEN_DIR/harnesses/pi/manifest.yaml" ]; then
    echo "   🔗 Removing Pi launchers..."
    while IFS=' ' read -r _src _dest_name; do
        _dest="$INSTALL_DIR/$_dest_name"
        if [ -f "$_dest" ]; then
            rm -f "$_dest"
            echo "   ✅ Removed Pi launcher: $_dest_name"
        fi
    done < <(manifest_launchers pi 2>/dev/null)
else
    # Fallback: remove known launcher names
    for _launcher in pi-build pi-debug pi-shape pi-ops; do
        if [ -f "$INSTALL_DIR/$_launcher" ]; then
            rm -f "$INSTALL_DIR/$_launcher"
            echo "   ✅ Removed Pi launcher: $_launcher"
        fi
    done
fi

# Remove orphaned legacy codex-* launchers (removed from source; never in any
# manifest). Hardcoded known names.
for _codex in codex-build codex-inspector codex-refactor codex-shape; do
    if [ -f "$INSTALL_DIR/$_codex" ]; then
        rm -f "$INSTALL_DIR/$_codex"
        echo "   ✅ Removed orphaned legacy launcher: $_codex"
    fi
done

# Remove pi agents
PI_AGENTS_DIR="$HOME/.pi/agent/agents"
if [ -d "$PI_AGENTS_DIR" ]; then
    _pi_agent_count=0
    for _agent in "$PI_AGENTS_DIR"/*.md; do
        [ -f "$_agent" ] || continue
        rm -f "$_agent"
        _pi_agent_count=$((_pi_agent_count + 1))
    done
    if [ "$_pi_agent_count" -gt 0 ]; then
        echo "   ✅ Removed $_pi_agent_count Pi agent(s) from $PI_AGENTS_DIR"
    else
        echo "   ℹ️  No Pi agents found in $PI_AGENTS_DIR"
    fi
else
    echo "   ℹ️  Pi agents dir not found: $PI_AGENTS_DIR"
fi

# Remove pi prompts
PI_PROMPTS_DIR="$HOME/.pi/agent/prompts"
if [ -d "$PI_PROMPTS_DIR" ]; then
    _pi_prompt_count=0
    for _prompt in "$PI_PROMPTS_DIR"/*.md; do
        [ -f "$_prompt" ] || continue
        rm -f "$_prompt"
        _pi_prompt_count=$((_pi_prompt_count + 1))
    done
    if [ "$_pi_prompt_count" -gt 0 ]; then
        echo "   ✅ Removed $_pi_prompt_count Pi prompt(s) from $PI_PROMPTS_DIR"
    else
        echo "   ℹ️  No Pi prompts found in $PI_PROMPTS_DIR"
    fi
else
    echo "   ℹ️  Pi prompts dir not found: $PI_PROMPTS_DIR"
fi

# Remove pi zsh completions
# Override search list via env: ZSH_COMPLETION_DIRS="/path1:/path2" (colon-separated, same toggle as install.sh).
IFS=':' read -ra _ZSH_COMPLETION_DIRS <<<"${ZSH_COMPLETION_DIRS:-/usr/local/share/zsh/site-functions:$HOME/.zsh/completions:$HOME/.local/share/zsh/site-functions}"
_ZSH_COMPLETION_DST=""
for _dir in "${_ZSH_COMPLETION_DIRS[@]}"; do
    if [ -d "$_dir" ] && [ -w "$_dir" ]; then
        _ZSH_COMPLETION_DST="$_dir"
        break
    fi
done

if [ -n "$_ZSH_COMPLETION_DST" ] && command -v manifest_completions >/dev/null 2>&1 && [ -f "$CODEGEN_DIR/harnesses/pi/manifest.yaml" ]; then
    while IFS= read -r _comp; do
        _comp_path="$_ZSH_COMPLETION_DST/$_comp"
        if [ -f "$_comp_path" ]; then
            rm -f "$_comp_path"
            echo "   ✅ Removed Pi zsh completion: $_comp"
        fi
    done < <(manifest_completions pi 2>/dev/null)
else
    # Fallback: remove known completion names
    for _comp in _pi-build _pi-debug _pi-shape _pi-ops; do
        for _dir in "${_ZSH_COMPLETION_DIRS[@]}"; do
            if [ -f "$_dir/$_comp" ]; then
                rm -f "$_dir/$_comp"
                echo "   ✅ Removed Pi zsh completion: $_comp from $_dir"
            fi
        done
    done
fi

echo ""
echo "✅ Uninstallation complete!"
echo ""
echo "💡 Note: This does not remove $INSTALL_DIR from your PATH"
echo "   If you no longer need it, you can manually remove it from your shell configuration"
echo ""
echo "💡 Restart your terminal or run 'source $RC_FILE' to apply changes"
