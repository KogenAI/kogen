#!/bin/bash

# Optimum Codegen CLI Installation Script
# Usage: install.sh [--all]
#   By default installs Claude Code only.
#   Pass --all to also install Codex and Cursor CLI.
#
# Environment variables:
#   STACK — informational only; does not affect which agents are installed.
#     All 8 subagent templates (shared, phoenix, static, platform) are always
#     rendered and installed regardless of this variable.

set -e

INSTALL_ALL=false
for arg in "$@"; do
    [ "$arg" = "--all" ] && INSTALL_ALL=true
done

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

# One-time migration: if any per-stack manifests (.installed-by-ocg.<stack>)
# exist from a previous install, union them into the unsuffixed manifest and
# delete the per-stack files. This preserves tracking continuity on hosts that
# previously ran STACK=platform or STACK=static make install.
_any_stack_manifests=$(ls "$CLAUDE_AGENTS_DIR"/.installed-by-ocg.* 2>/dev/null || true)
if [ -n "$_any_stack_manifests" ]; then
    # shellcheck disable=SC2086
    sort -u $CLAUDE_AGENTS_DIR/.installed-by-ocg.* >"$AGENTS_MANIFEST"
    # shellcheck disable=SC2086
    rm -f $CLAUDE_AGENTS_DIR/.installed-by-ocg.*
fi

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

# Delete stale agents — files listed in the previous manifest but not in the
# current install set.
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

# Write the combined manifest so the next install knows what this run installed.
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
    echo "🔧 Setting up Codex configuration..."
    mkdir -p "$HOME/.codex/agents"
    mkdir -p "$HOME/.codex/hooks"

    # Copy hook scripts
    for hook_script in "$CODEGEN_DIR/templates/shared/hooks/codex-inspector-bash-guard.sh" "$CODEGEN_DIR/templates/shared/hooks/codex-inspector-write-guard.sh"; do
        if [ -f "$hook_script" ]; then
            cp "$hook_script" "$HOME/.codex/hooks/"
            chmod +x "$HOME/.codex/hooks/$(basename "$hook_script")"
        fi
    done

    # Install agent TOML files
    echo "   🤖 Installing Codex agents..."
    CODEX_AGENTS_MANIFEST="$HOME/.codex/agents/.installed-by-ocg"
    CURRENT_CODEX_AGENTS=()
    if [ -d "$CODEGEN_DIR/templates/generated/codex/agents" ]; then
        for agent_file in "$CODEGEN_DIR/templates/generated/codex/agents"/*.toml; do
            if [ -f "$agent_file" ]; then
                agent_name=$(basename "$agent_file")
                cp "$agent_file" "$HOME/.codex/agents/"
                echo "   ✅ Installed Codex agent: ${agent_name%.toml}"
                CURRENT_CODEX_AGENTS+=("$agent_name")
            fi
        done
    fi
    # Delete stale TOML agents from previous installs
    if [ -f "$CODEX_AGENTS_MANIFEST" ]; then
        while IFS= read -r old_agent; do
            if [ -n "$old_agent" ]; then
                still_present=false
                for cur in "${CURRENT_CODEX_AGENTS[@]}"; do
                    [ "$cur" = "$old_agent" ] && still_present=true && break
                done
                if [ "$still_present" = "false" ] && [ -f "$HOME/.codex/agents/$old_agent" ]; then
                    rm -f "$HOME/.codex/agents/$old_agent"
                    echo "   🗑️  Removed stale Codex agent: ${old_agent%.toml}"
                fi
            fi
        done <"$CODEX_AGENTS_MANIFEST"
    fi
    printf '%s\n' "${CURRENT_CODEX_AGENTS[@]}" >"$CODEX_AGENTS_MANIFEST"

    # Install/merge config.toml
    if [ -f "$CODEGEN_DIR/templates/generated/codex/config.toml" ]; then
        if [ -f "$HOME/.codex/config.toml" ]; then
            # Merge: preserve user's model/review_model/theme keys; overwrite [agents]/[features]/[[hooks.PreToolUse]]
            python3 - "$HOME/.codex/config.toml" "$CODEGEN_DIR/templates/generated/codex/config.toml" <<'PY'
import sys, shutil
try:
    import tomllib
except ImportError:
    try:
        import tomli as tomllib
    except ImportError:
        print("   ⚠️  tomllib/tomli not available — overwriting config.toml (user keys NOT preserved)")
        shutil.copy2(sys.argv[2], sys.argv[1])
        sys.exit(0)
try:
    import tomli_w
except ImportError:
    import subprocess
    r = subprocess.run(["pip3", "install", "--user", "--quiet", "tomli_w", "--break-system-packages"], capture_output=True)
    if r.returncode != 0:
        subprocess.run(["pip3", "install", "--user", "--quiet", "tomli_w"], capture_output=True)
    try:
        import tomli_w
    except ImportError:
        print("   ⚠️  tomli_w unavailable — overwriting config.toml (user keys NOT preserved)")
        shutil.copy2(sys.argv[2], sys.argv[1])
        sys.exit(0)
with open(sys.argv[1], "rb") as f:
    user = tomllib.load(f)
with open(sys.argv[2], "rb") as f:
    generated = tomllib.load(f)
# generated keys take priority; user-only keys are preserved via **user base
merged = {**user, **generated}
with open(sys.argv[1], "wb") as f:
    tomli_w.dump(merged, f)
print("   ✅ Codex config.toml merged (user keys preserved)")
PY
        else
            cp "$CODEGEN_DIR/templates/generated/codex/config.toml" "$HOME/.codex/config.toml"
            echo "   ✅ Codex config.toml installed"
        fi
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

    echo "   🤖 Installing Cursor CLI agents..."
    CURSOR_SUBAGENTS_DIR="$HOME/.cursor/agents"
    mkdir -p "$CURSOR_SUBAGENTS_DIR"

    CURSOR_AGENTS_MANIFEST="$CURSOR_SUBAGENTS_DIR/.installed-by-ocg"
    CURRENT_CURSOR_AGENTS=()
    if [ -d "$CODEGEN_DIR/templates/generated/cursor/agents" ]; then
        for agent_file in "$CODEGEN_DIR/templates/generated/cursor/agents"/*.md; do
            if [ -f "$agent_file" ]; then
                agent_name=$(basename "$agent_file")
                cp "$agent_file" "$CURSOR_SUBAGENTS_DIR/"
                echo "   ✅ Installed Cursor agent: ${agent_name%.md}"
                CURRENT_CURSOR_AGENTS+=("$agent_name")
            fi
        done
    fi
    # Delete stale Cursor agents from previous installs
    if [ -f "$CURSOR_AGENTS_MANIFEST" ]; then
        while IFS= read -r old_agent; do
            if [ -n "$old_agent" ]; then
                still_present=false
                for cur in "${CURRENT_CURSOR_AGENTS[@]}"; do
                    [ "$cur" = "$old_agent" ] && still_present=true && break
                done
                if [ "$still_present" = "false" ] && [ -f "$CURSOR_SUBAGENTS_DIR/$old_agent" ]; then
                    rm -f "$CURSOR_SUBAGENTS_DIR/$old_agent"
                    echo "   🗑️  Removed stale Cursor agent: ${old_agent%.md}"
                fi
            fi
        done <"$CURSOR_AGENTS_MANIFEST"
    fi
    printf '%s\n' "${CURRENT_CURSOR_AGENTS[@]}" >"$CURSOR_AGENTS_MANIFEST"
fi

# Create OCG config directory
mkdir -p "$HOME/.ocg"

if [ ! -f "$HOME/.ocg/config.json" ]; then
    if [ "$INSTALL_ALL" = true ]; then
        echo ""
        echo "🤖 AI Agent Configuration"
        echo "   Claude Code, Codex, and Cursor CLI are now installed."
        echo "   Which should be your default AI agent?"
        echo "   1) claude (Claude Code)"
        echo "   2) codex (Codex)"
        echo "   3) cursor (Cursor CLI)"
        echo ""
        read -p "   Choose [1-3]: " choice

        case $choice in
        1) default_agent="claude" ;;
        2) default_agent="codex" ;;
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
        "codex": { "enabled": false },
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
