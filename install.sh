#!/bin/bash

# Optimum Codegen CLI Installation Script
# Usage: install.sh [--harness=<list>]
#   --harness=claude,codex,cursor — comma-separated list of harnesses to install.
#   When omitted, installs all three harnesses (claude, codex, cursor).
#   Invalid harness names cause a fail-fast exit with a helpful message.
#
# Examples:
#   install.sh                          # installs claude + codex + cursor
#   install.sh --harness=claude         # claude only
#   install.sh --harness=codex,cursor   # codex + cursor, skip claude

set -e

HARNESSES=()
for arg in "$@"; do
    case "$arg" in
    --harness=*)
        list="${arg#--harness=}"
        if [ -z "$list" ]; then
            echo "❌ --harness= requires a value (one or more of: claude, codex, cursor)" >&2
            exit 1
        fi
        IFS=',' read -ra _tokens <<<"$list"
        for tok in "${_tokens[@]}"; do
            tok="$(echo "$tok" | tr -d '[:space:]')"
            [ -z "$tok" ] && continue
            case "$tok" in
            claude | codex | cursor)
                # Deduplicate
                already=false
                for existing in "${HARNESSES[@]}"; do
                    [ "$existing" = "$tok" ] && already=true && break
                done
                [ "$already" = "false" ] && HARNESSES+=("$tok")
                ;;
            *)
                echo "❌ Unknown harness: '$tok' (expected one or more of: claude, codex, cursor)" >&2
                exit 1
                ;;
            esac
        done
        ;;
    *)
        echo "❌ Unknown argument: '$arg' (usage: install.sh [--harness=<list>])" >&2
        exit 1
        ;;
    esac
done

# Default = all three harnesses when --harness flag omitted
if [ ${#HARNESSES[@]} -eq 0 ]; then
    HARNESSES=("claude" "codex" "cursor")
fi

harness_enabled() {
    local target="$1"
    for h in "${HARNESSES[@]}"; do
        [ "$h" = "$target" ] && return 0
    done
    return 1
}

# content_stable_cp <src> <dst>
# Copies src to dst ONLY when dst doesn't exist or its bytes differ from src.
# Skipping identical files preserves mtime and keeps the Claude Code prompt
# cache valid (each write busts cache fleet-wide on the next session).
# Returns 0 in both cases; caller can inspect exit code of the underlying cp.
content_stable_cp() {
    local src="$1"
    local dst="$2"
    if [ -f "$dst" ] && cmp -s "$src" "$dst"; then
        return 0 # identical — skip write
    fi
    cp "$src" "$dst"
}

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
    content_stable_cp "$CODEGEN_DIR/templates/recipes-README.md" "$RECIPES_DIR/README.md"
    echo "   ✅ Recipes README installed"
fi

echo ""
echo "🚀 Generating AI agent templates..."

# Generate templates for the selected harnesses. generate.sh accepts:
#   all | claude | codex | cursor
# We pass `all` only when all three are selected; otherwise we invoke per-harness.
if harness_enabled claude && harness_enabled codex && harness_enabled cursor; then
    "$CODEGEN_DIR/templates/generator/generate.sh" all
else
    for h in "${HARNESSES[@]}"; do
        "$CODEGEN_DIR/templates/generator/generate.sh" "$h"
    done
fi

# Render user-app orchestrator AGENTS templates (.j2 -> .md) back into context repo.
# These .md files are symlinked into user-app workspaces by Combobulate.Apps.copy_agents_md/2
# at provision time, so they must exist as regenerable artifacts beside their .j2 source.
# Each template renders TWICE:
#   codex render  → AGENTS-{variant}.md  (→ See pointers; consumed by Codex/Cursor)
#   claude render → CLAUDE-{variant}.md  (@ auto-load imports; consumed by Claude Code)
echo ""
echo "🚀 Rendering user-app AGENTS templates (.j2 -> .md)..."
APPS_DIR="$CONTEXT_DIR/apps"
PROCESS_TEMPLATE="$CODEGEN_DIR/templates/generator/process_template.py"

render_to_md() {
    local src="$1"
    local tool_name="$2"
    local dst="$3"
    if [ -f "$src" ]; then
        local tmp
        tmp="$(mktemp)"
        OCG_CONTEXT_DIR="$CONTEXT_DIR" python3 "$PROCESS_TEMPLATE" "$src" "$tool_name" false >"$tmp"
        if [ ! -f "$dst" ] || ! cmp -s "$tmp" "$dst"; then
            mv "$tmp" "$dst"
            echo "   ✅ Rendered $(basename "$dst") (tool=$tool_name)"
        else
            rm -f "$tmp"
            echo "   ✅ $(basename "$dst") already up to date"
        fi
    else
        echo "   ⚠️  $src missing — skipping render"
    fi
}

for base in AGENTS-phoenix AGENTS-static; do
    src="$APPS_DIR/$base.md.j2"
    # codex render → canonical AGENTS-{variant}.md
    render_to_md "$src" codex "$APPS_DIR/$base.md"
    # claude render → CLAUDE-{variant}.md  (strip "AGENTS-" prefix, add "CLAUDE-")
    variant="${base#AGENTS-}"
    render_to_md "$src" claude "$APPS_DIR/CLAUDE-${variant}.md"
done

# Clean up generated templates after installation
cleanup_generated_templates() {
    echo "   🧹 Cleaning up generated templates..."
    rm -rf "$CODEGEN_DIR/templates/generated/"
    echo "   ✅ Generated templates cleaned up"
}

if harness_enabled claude; then
    echo ""
    echo "🚀 Setting up Claude Code configuration..."

    CLAUDE_SETTINGS_DIR="$HOME/.claude"
    CLAUDE_SETTINGS_FILE="$CLAUDE_SETTINGS_DIR/settings.json"
    CLAUDE_COMMANDS_DIR="$CLAUDE_SETTINGS_DIR/commands"

    mkdir -p "$CLAUDE_SETTINGS_DIR"
    mkdir -p "$CLAUDE_COMMANDS_DIR"

    # Install generated Claude Code files
    if [ -f "$CODEGEN_DIR/templates/generated/claude-code/claude-code-settings.json" ]; then
        content_stable_cp "$CODEGEN_DIR/templates/generated/claude-code/claude-code-settings.json" "$CLAUDE_SETTINGS_FILE"
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
                content_stable_cp "$hook_file" "$CLAUDE_SETTINGS_DIR/hooks/$hook_name"
                chmod +x "$CLAUDE_SETTINGS_DIR/hooks/$hook_name"
                echo "   ✅ ${hook_name} hook installed at: $CLAUDE_SETTINGS_DIR/hooks/$hook_name"
            fi
        done

        # Prune orphan hooks: remove any *.sh in $CLAUDE_SETTINGS_DIR/hooks
        # that no longer exists in templates/shared/hooks/. Keeps installs in sync
        # when hooks are deleted upstream. Skips the lib/ subdirectory.
        if [ -d "$CLAUDE_SETTINGS_DIR/hooks" ]; then
            for installed_hook in "$CLAUDE_SETTINGS_DIR/hooks"/*.sh; do
                [ -f "$installed_hook" ] || continue
                hook_basename=$(basename "$installed_hook")
                if [ ! -f "$CODEGEN_DIR/templates/shared/hooks/$hook_basename" ]; then
                    rm -f "$installed_hook"
                    echo "   Removed orphan hook: $hook_basename"
                fi
            done
        fi

        # Install hooks lib (sourced by every hook script for parse_input/deny/etc.)
        if [ -d "$CODEGEN_DIR/templates/shared/hooks/lib" ]; then
            mkdir -p "$CLAUDE_SETTINGS_DIR/hooks/lib"
            for lib_file in "$CODEGEN_DIR/templates/shared/hooks/lib"/*; do
                if [ -f "$lib_file" ]; then
                    content_stable_cp "$lib_file" "$CLAUDE_SETTINGS_DIR/hooks/lib/$(basename "$lib_file")"
                fi
            done
            echo "   ✅ Hooks lib installed at: $CLAUDE_SETTINGS_DIR/hooks/lib/"
        fi
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
                content_stable_cp "$cmd_file" "$CLAUDE_COMMANDS_DIR/$cmd_name"
                echo "   ✅ Installed command: /${cmd_name%.md}"
                CURRENT_COMMANDS+=("$cmd_name")
            fi
        done
    fi

    # Delete stale commands — any .md in commands dir not in the current install set.
    for installed_cmd in "$CLAUDE_COMMANDS_DIR"/*.md; do
        [ -f "$installed_cmd" ] || continue
        cmd_basename=$(basename "$installed_cmd")
        still_present=false
        for cur in "${CURRENT_COMMANDS[@]}"; do
            [ "$cur" = "$cmd_basename" ] && still_present=true && break
        done
        if [ "$still_present" = "false" ]; then
            rm -f "$installed_cmd"
            echo "   🗑️  Removed stale command: /${cmd_basename%.md}"
        fi
    done

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
                content_stable_cp "$agent_file" "$CLAUDE_AGENTS_DIR/$agent_name"
                echo "   ✅ Installed Claude sub agent: ${agent_name%.md}"
                CURRENT_AGENTS+=("$agent_name")
            fi
        done
    fi

    # Delete stale agents — any .md in the agents dir not in the current install set.
    # Safety: skip prune entirely when CURRENT_AGENTS is empty (generator failed / dir missing) —
    # never wipe the whole agents dir on a script bug.
    if [ ${#CURRENT_AGENTS[@]} -eq 0 ]; then
        echo "   ⚠️  Skipping Claude agent prune — install set is empty (generator may have failed)"
    else
        for installed_agent in "$CLAUDE_AGENTS_DIR"/*.md; do
            [ -f "$installed_agent" ] || continue
            agent_basename=$(basename "$installed_agent")
            still_present=false
            for cur in "${CURRENT_AGENTS[@]}"; do
                [ "$cur" = "$agent_basename" ] && still_present=true && break
            done
            if [ "$still_present" = "false" ]; then
                rm -f "$installed_agent"
                echo "   🗑️  Removed stale agent: ${agent_basename%.md}"
            fi
        done
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

    # Install yq for YAML processing
    if ! command -v yq >/dev/null 2>&1; then
        if [[ "$OSTYPE" == "darwin"* ]]; then
            echo "   📦 Installing yq with brew..."
            if command -v brew >/dev/null 2>&1; then
                brew install yq
                echo "   ✅ yq installed"
            else
                echo "   ❌ Homebrew not found. Please install yq manually:"
                echo "      brew install yq"
                exit 1
            fi
        elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
            echo "   📦 Installing yq with apt..."
            sudo apt-get update && sudo apt-get install -y yq
            echo "   ✅ yq installed"
        else
            echo "Warning: yq installation not supported on this OS. Install manually: https://github.com/mikefarah/yq"
        fi
    else
        echo "   ✅ yq already installed"
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

    # Install claude-build wrapper
    echo ""
    echo "🚀 Installing claude-build wrapper..."

    content_stable_cp "$CODEGEN_DIR/templates/shared/claude-build.sh" "$INSTALL_DIR/claude-build"
    chmod +x "$INSTALL_DIR/claude-build"
    echo "   ✅ claude-build wrapper installed at: $INSTALL_DIR/claude-build"

    # De-register legacy alias from rc file (idempotent)
    if grep -q "alias claude-build=" "$RC_FILE" 2>/dev/null; then
        sed -i '' '/^# Optimum Codegen claude-build alias$/d; /^alias claude-build=/d' "$RC_FILE"
        echo "   🗑️  Removed legacy claude-build alias from $RC_FILE"
    fi

    # Install claude-design wrapper
    echo ""
    echo "🚀 Installing claude-design wrapper..."

    content_stable_cp "$CODEGEN_DIR/templates/shared/claude-design.sh" "$INSTALL_DIR/claude-design"
    chmod +x "$INSTALL_DIR/claude-design"
    echo "   ✅ claude-design wrapper installed at: $INSTALL_DIR/claude-design"

    # De-register legacy alias from rc file (idempotent)
    if grep -q "alias claude-design=" "$RC_FILE" 2>/dev/null; then
        sed -i '' '/^# Optimum Codegen claude-design alias$/d; /^alias claude-design=/d' "$RC_FILE"
        echo "   🗑️  Removed legacy claude-design alias from $RC_FILE"
    fi

    # Install claude-debug wrapper
    echo ""
    echo "🚀 Installing claude-debug wrapper..."

    content_stable_cp "$CODEGEN_DIR/templates/shared/claude-debug.sh" "$INSTALL_DIR/claude-debug"
    chmod +x "$INSTALL_DIR/claude-debug"
    echo "   ✅ claude-debug wrapper installed at: $INSTALL_DIR/claude-debug"

    # De-register legacy alias from rc file (idempotent)
    if grep -q "alias claude-debug=" "$RC_FILE" 2>/dev/null; then
        sed -i '' '/^# Optimum Codegen claude-debug alias$/d; /^alias claude-debug=/d' "$RC_FILE"
        echo "   🗑️  Removed legacy claude-debug alias from $RC_FILE"
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
fi # harness_enabled claude

if harness_enabled codex; then
    echo ""
    echo "🔧 Setting up Codex configuration..."

    echo "🤖 Installing Codex..."
    hash -r 2>/dev/null || true
    if command -v codex >/dev/null 2>&1; then
        echo "   ✅ Codex already installed"
    else
        npm install -g "@openai/codex@latest"
        echo "   ✅ Codex installed"
    fi

    mkdir -p "$HOME/.codex/agents"
    mkdir -p "$HOME/.codex/hooks"

    # Copy hook scripts and remove stale ones
    CURRENT_CODEX_HOOKS=()
    for hook_script in "$CODEGEN_DIR/templates/shared/hooks"/codex-*.sh; do
        [ -f "$hook_script" ] || continue
        content_stable_cp "$hook_script" "$HOME/.codex/hooks/$(basename "$hook_script")"
        chmod +x "$HOME/.codex/hooks/$(basename "$hook_script")"
        CURRENT_CODEX_HOOKS+=("$(basename "$hook_script")")
    done
    for installed_hook in "$HOME/.codex/hooks"/*.sh; do
        [ -f "$installed_hook" ] || continue
        hook_basename=$(basename "$installed_hook")
        still_present=false
        for cur in "${CURRENT_CODEX_HOOKS[@]}"; do
            [ "$cur" = "$hook_basename" ] && still_present=true && break
        done
        if [ "$still_present" = "false" ]; then
            rm -f "$installed_hook"
            echo "   🗑️  Removed stale Codex hook: $hook_basename"
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
                content_stable_cp "$agent_file" "$HOME/.codex/agents/$agent_name"
                echo "   ✅ Installed Codex agent: ${agent_name%.toml}"
                CURRENT_CODEX_AGENTS+=("$agent_name")
            fi
        done
    fi
    # Delete stale TOML agents — any .toml in agents dir not in the current install set.
    # Safety: skip prune when install set is empty (generator failure).
    if [ ${#CURRENT_CODEX_AGENTS[@]} -eq 0 ]; then
        echo "   ⚠️  Skipping Codex agent prune — install set is empty (generator may have failed)"
    else
        for installed_agent in "$HOME/.codex/agents"/*.toml; do
            [ -f "$installed_agent" ] || continue
            agent_basename=$(basename "$installed_agent")
            still_present=false
            for cur in "${CURRENT_CODEX_AGENTS[@]}"; do
                [ "$cur" = "$agent_basename" ] && still_present=true && break
            done
            if [ "$still_present" = "false" ]; then
                rm -f "$installed_agent"
                echo "   🗑️  Removed stale Codex agent: ${agent_basename%.toml}"
            fi
        done
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
            content_stable_cp "$CODEGEN_DIR/templates/generated/codex/config.toml" "$HOME/.codex/config.toml"
            echo "   ✅ Codex config.toml installed"
        fi
    fi
fi # harness_enabled codex

if harness_enabled cursor; then
    echo ""
    echo "🔧 Setting up Cursor CLI configuration..."

    mkdir -p "$HOME/.cursor"

    echo "   📁 Installing Cursor CLI custom commands..."
    CURSOR_COMMANDS_DIR="$HOME/.cursor/commands"
    mkdir -p "$CURSOR_COMMANDS_DIR"

    CURRENT_CURSOR_COMMANDS=()
    if [ -d "$CODEGEN_DIR/templates/shared/commands" ]; then
        for cmd_file in "$CODEGEN_DIR/templates/shared/commands"/*.md; do
            if [ -f "$cmd_file" ]; then
                cmd_name=$(basename "$cmd_file")
                content_stable_cp "$cmd_file" "$CURSOR_COMMANDS_DIR/$cmd_name"
                echo "   ✅ Installed Cursor command: /${cmd_name%.md}"
                CURRENT_CURSOR_COMMANDS+=("$cmd_name")
            fi
        done
    fi

    # Delete stale commands — any .md in commands dir not in the current install set.
    for installed_cmd in "$CURSOR_COMMANDS_DIR"/*.md; do
        [ -f "$installed_cmd" ] || continue
        cmd_basename=$(basename "$installed_cmd")
        still_present=false
        for cur in "${CURRENT_CURSOR_COMMANDS[@]}"; do
            [ "$cur" = "$cmd_basename" ] && still_present=true && break
        done
        if [ "$still_present" = "false" ]; then
            rm -f "$installed_cmd"
            echo "   🗑️  Removed stale Cursor command: /${cmd_basename%.md}"
        fi
    done

    echo "   🤖 Installing Cursor CLI agents..."
    CURSOR_SUBAGENTS_DIR="$HOME/.cursor/agents"
    mkdir -p "$CURSOR_SUBAGENTS_DIR"

    CURSOR_AGENTS_MANIFEST="$CURSOR_SUBAGENTS_DIR/.installed-by-ocg"
    CURRENT_CURSOR_AGENTS=()
    if [ -d "$CODEGEN_DIR/templates/generated/cursor/agents" ]; then
        for agent_file in "$CODEGEN_DIR/templates/generated/cursor/agents"/*.md; do
            if [ -f "$agent_file" ]; then
                agent_name=$(basename "$agent_file")
                content_stable_cp "$agent_file" "$CURSOR_SUBAGENTS_DIR/$agent_name"
                echo "   ✅ Installed Cursor agent: ${agent_name%.md}"
                CURRENT_CURSOR_AGENTS+=("$agent_name")
            fi
        done
    fi
    # Delete stale Cursor agents — any .md in agents dir not in the current install set.
    # Safety: skip prune when install set is empty (generator failure).
    if [ ${#CURRENT_CURSOR_AGENTS[@]} -eq 0 ]; then
        echo "   ⚠️  Skipping Cursor agent prune — install set is empty (generator may have failed)"
    else
        for installed_agent in "$CURSOR_SUBAGENTS_DIR"/*.md; do
            [ -f "$installed_agent" ] || continue
            agent_basename=$(basename "$installed_agent")
            still_present=false
            for cur in "${CURRENT_CURSOR_AGENTS[@]}"; do
                [ "$cur" = "$agent_basename" ] && still_present=true && break
            done
            if [ "$still_present" = "false" ]; then
                rm -f "$installed_agent"
                echo "   🗑️  Removed stale Cursor agent: ${agent_basename%.md}"
            fi
        done
    fi
    printf '%s\n' "${CURRENT_CURSOR_AGENTS[@]}" >"$CURSOR_AGENTS_MANIFEST"
fi

# Create OCG config directory
mkdir -p "$HOME/.ocg"

if [ ! -f "$HOME/.ocg/config.json" ]; then
    # If only one harness was selected, use it as the default without prompting.
    # Otherwise prompt the user among the selected harnesses.
    if [ ${#HARNESSES[@]} -eq 1 ]; then
        default_agent="${HARNESSES[0]}"
    else
        echo ""
        echo "🤖 AI Agent Configuration"
        echo "   The following AI agents are installed: ${HARNESSES[*]}"
        echo "   Which should be your default AI agent?"
        i=1
        for h in "${HARNESSES[@]}"; do
            echo "   $i) $h"
            i=$((i + 1))
        done
        echo ""
        read -p "   Choose [1-${#HARNESSES[@]}]: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#HARNESSES[@]} ]; then
            default_agent="${HARNESSES[$((choice - 1))]}"
        else
            default_agent="${HARNESSES[0]}"
        fi
    fi

    claude_enabled=false
    codex_enabled=false
    cursor_enabled=false
    harness_enabled claude && claude_enabled=true
    harness_enabled codex && codex_enabled=true
    harness_enabled cursor && cursor_enabled=true

    cat >"$HOME/.ocg/config.json" <<EOF
{
    "default_agent": "$default_agent",
    "agents": {
        "claude": { "enabled": $claude_enabled },
        "codex": { "enabled": $codex_enabled },
        "cursor": { "enabled": $cursor_enabled }
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

# Format context repo after install finishes regenerating files
CONTEXT_DIR="${OCG_CONTEXT_DIR:-$HOME/Areas/Optimum/context}"
if [ -d "$CONTEXT_DIR" ]; then
	npx prettier -w --log-level error "$CONTEXT_DIR"
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
echo "💡 Restart your terminal or run 'source $RC_FILE' for autocompletion and Claude Code custom commands"
echo "💡 Test the installation by running: ocg help"
echo "💡 Test Claude Code custom commands by running: claude (then try /write-drop)"
echo "💡 Next: Run 'ocg setup' in your project directory to install project-specific tools"
