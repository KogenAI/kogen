#!/bin/bash

# Optimum Codegen CLI Installation Script
# Usage: install.sh [--harness=<list>]
#   --harness=claude,pi — comma-separated list of harnesses to install.
#   When omitted, installs both harnesses (claude, pi).
#   Invalid harness names cause a fail-fast exit with a helpful message.
#
# Environment variables (all optional):
#   OCG_DEFAULT_AGENT=<claude|pi>   — skips agent-selection prompt; must match an installed harness.
#   OCG_NONINTERACTIVE=1            — auto-trusts nested .mise.toml; hard-fails if a prompt would block.
#                                     Requires OCG_DEFAULT_AGENT when multiple harnesses are installed.
#   OCG_CODEGEN_DIR=<path>          — dispatch fallback used by codegen-call when harnesses/ symlink unavailable.
#
# Examples:
#   install.sh                          # installs claude + pi
#   install.sh --harness=claude         # claude only
#   install.sh --harness=pi             # pi only, skip claude

set -e

DRY_RUN=false
HARNESSES=()
for arg in "$@"; do
    case "$arg" in
    --dry-run)
        DRY_RUN=true
        ;;
    --harness=*)
        list="${arg#--harness=}"
        if [ -z "$list" ]; then
            echo "❌ --harness= requires a value (one or more of: claude, pi)" >&2
            exit 1
        fi
        IFS=',' read -ra _tokens <<<"$list"
        for tok in "${_tokens[@]}"; do
            tok="$(echo "$tok" | tr -d '[:space:]')"
            [ -z "$tok" ] && continue
            case "$tok" in
            claude | pi)
                # Deduplicate
                already=false
                for existing in "${HARNESSES[@]}"; do
                    [ "$existing" = "$tok" ] && already=true && break
                done
                [ "$already" = "false" ] && HARNESSES+=("$tok")
                ;;
            *)
                echo "❌ Unknown harness: '$tok' (expected one or more of: claude, pi)" >&2
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

# Default = all harnesses when --harness flag omitted
if [ ${#HARNESSES[@]} -eq 0 ]; then
    HARNESSES=("claude" "pi")
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

# Wire dispatch path: codegen-call resolves $SCRIPT_DIR/harnesses at runtime.
# A sibling harnesses/ symlink in INSTALL_DIR makes tier-1 dispatch resolve without env-var fallback.
HARNESSES_SYMLINK="$INSTALL_DIR/harnesses"
rm -f "$HARNESSES_SYMLINK"
ln -sfn "$CODEGEN_DIR/harnesses" "$HARNESSES_SYMLINK"
if [ ! -d "$HARNESSES_SYMLINK/" ]; then
    echo "❌ could not wire dispatch path: $HARNESSES_SYMLINK -> $CODEGEN_DIR/harnesses. Set fallback: export OCG_CODEGEN_DIR=$CODEGEN_DIR"
    exit 1
fi

# Wire shared/ path: codegen-scaffold resolves $SCRIPT_DIR/shared at runtime.
# A sibling shared/ symlink in INSTALL_DIR makes it resolve without a full CODEGEN_DIR.
SHARED_SYMLINK="$INSTALL_DIR/shared"
rm -f "$SHARED_SYMLINK"
ln -sfn "$CODEGEN_DIR/shared" "$SHARED_SYMLINK"

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
    echo "   export OCG_CODEGEN_DIR=$CODEGEN_DIR   # dispatch fallback if harnesses/ symlink unavailable"
else
    echo "   ✅ $INSTALL_DIR is already in your PATH"
    echo "   export OCG_CODEGEN_DIR=$CODEGEN_DIR   # dispatch fallback if harnesses/ symlink unavailable"
fi

echo ""
echo "🚀 Setting up recipes directory..."

# Context repository is now part of codegen as codegen/shared/ — no separate clone needed.
RECIPES_DIR="$CODEGEN_DIR/shared/recipes"
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

# Platform symlinks: expose shared/ tables under codegen/ for agents resolving relative paths.
# Agents and tools resolve codegen/recipes/INDEX.md, codegen/rules/INDEX.md, etc. relative to
# the repo root; these symlinks make $CODEGEN_DIR/codegen/<x> -> $CODEGEN_DIR/shared/<x>.
mkdir -p "$CODEGEN_DIR/codegen"
for _link in rules recipes usage_rules subagents; do
    ln -sfn "$CODEGEN_DIR/shared/$_link" "$CODEGEN_DIR/codegen/$_link"
    if [ ! -e "$CODEGEN_DIR/codegen/$_link" ]; then
        echo "❌ platform symlink unresolved: codegen/$_link -> shared/$_link"
        exit 1
    fi
done

# Install root node_modules (ajv, playwright, prettier) so schema-validate.js and render-check.js
# can resolve their dependencies from $CODEGEN_DIR/node_modules.
# Skip if node_modules already present and up-to-date (idempotent).
if [ -f "$CODEGEN_DIR/package.json" ]; then
    if [ ! -d "$CODEGEN_DIR/node_modules/ajv" ]; then
        echo ""
        echo "📦 Installing root node deps (ajv, playwright, prettier)..."
        # Use MISE_SKIP_CONFIG=1 so the npm shim runs without requiring mise trust on HOME-derived configs.
        # This is safe: we only need npm here, not mise's tool version management.
        _npm_install_failed=0
        (cd "$CODEGEN_DIR" && MISE_SKIP_CONFIG=1 npm install) 2>&1 || _npm_install_failed=1
        if [ "$_npm_install_failed" -eq 1 ]; then
            echo "❌ root npm install failed — schema-validate/render-check need node_modules" >&2
            exit 1
        fi
    else
        echo "   ✅ Root node_modules/ajv already present — skipping npm install"
    fi
fi

# Install Chromium browser binary (required for static-site render verification).
# Only run if playwright is present (dev-dep); skip gracefully on production installs.
if command -v npm &>/dev/null && (cd "$CODEGEN_DIR" && npm list playwright >/dev/null 2>&1); then
    echo "📦 Installing Chromium browser binary (playwright)..."
    if (cd "$CODEGEN_DIR" && npx playwright install chromium) 2>&1; then
        echo "   ✅ Chromium browser binary installed"
    else
        echo "   ⚠️  Chromium install failed — static-site render gate will warn until installed manually. Run: npx playwright install chromium" >&2
    fi
else
    echo "   ⚠️  Skipping Chromium install (playwright not present; non-static install)"
fi

# Generate templates for the selected harnesses via unified manifest-driven generator.
# Source manifest helpers for launcher/completion iteration (used in harness install loop below).
# Upfront yq gate: generate.sh and manifest-lib.sh consume yq; fail fast before sourcing.
if ! command -v yq >/dev/null 2>&1; then
    echo "❌ yq required but not found — install it: brew install yq (macOS) | https://github.com/mikefarah/yq"
    exit 1
fi
if ! yq --version 2>&1 | grep -qi mikefarah; then
    echo "❌ installed yq is not mikefarah/yq (apt python-yq is incompatible) — install from https://github.com/mikefarah/yq"
    exit 1
fi
if [[ ! -f "$CODEGEN_DIR/templates/generator/manifest-lib.sh" ]]; then
    echo "❌ manifest-lib.sh not found at $CODEGEN_DIR/templates/generator/manifest-lib.sh — corrupt or incomplete checkout" >&2
    exit 1
fi
source "$CODEGEN_DIR/templates/generator/manifest-lib.sh"

# Pass all selected harnesses to generate.sh in one call.
bash "$CODEGEN_DIR/templates/generator/generate.sh" "${HARNESSES[@]}"

# Render user-app orchestrator AGENTS templates (.j2 -> .md) back into context repo.
# These .md files are symlinked into user-app workspaces (e.g. via a platform copy_agents_md step)
# at provision time, so they must exist as regenerable artifacts beside their .j2 source.
# Each template renders TWICE:
#   pi render     → AGENTS-{variant}.md  (→ See pointers; consumed by Pi)
#   claude render → CLAUDE-{variant}.md  (@ auto-load imports; consumed by Claude Code)
echo ""
echo "🚀 Rendering user-app AGENTS templates (.j2 -> .md)..."
APPS_DIR="$CODEGEN_DIR/shared/apps"
PROCESS_TEMPLATE="$CODEGEN_DIR/templates/generator/process_template.py"

render_to_md() {
    local src="$1"
    local tool_name="$2"
    local dst="$3"
    if [ -f "$src" ]; then
        local tmp
        tmp="$(mktemp)"
        python3 "$PROCESS_TEMPLATE" "$src" "$tool_name" false >"$tmp"
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
    # pi render → canonical AGENTS-{variant}.md
    render_to_md "$src" pi "$APPS_DIR/$base.md"
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

# ─── Manifest-driven harness install loop ─────────────────────────────────────
# Replaces the former inline claude + pi branches.
# Each harness's manifest.yaml declares its surface; this loop reads it.
#
# Zsh completions: install into first writable dir.
# Override search list via env: ZSH_COMPLETION_DIRS="/path1:/path2" (colon-separated).
# Default: /opt/homebrew/share/zsh/site-functions and $HOME/.zsh/completions.
IFS=':' read -ra ZSH_COMPLETION_DIRS <<<"${ZSH_COMPLETION_DIRS:-/opt/homebrew/share/zsh/site-functions:$HOME/.zsh/completions}"
ZSH_COMPLETION_DST=""
for _d in "${ZSH_COMPLETION_DIRS[@]}"; do
    if [ -d "$_d" ] && [ -w "$_d" ]; then
        ZSH_COMPLETION_DST="$_d"
        break
    fi
done

for _harness in "${HARNESSES[@]}"; do
    echo ""
    echo "🚀 Setting up $_harness harness..."

    case "$_harness" in
    claude)
        # ── Claude-specific: settings, hooks, commands, agents, deps ──────────
        CLAUDE_SETTINGS_DIR="$HOME/.claude"
        CLAUDE_SETTINGS_FILE="$CLAUDE_SETTINGS_DIR/settings.json"
        CLAUDE_COMMANDS_DIR="$CLAUDE_SETTINGS_DIR/commands"

        mkdir -p "$CLAUDE_SETTINGS_DIR"
        mkdir -p "$CLAUDE_COMMANDS_DIR"

        # Install settings
        if [ -f "$CODEGEN_DIR/templates/generated/claude-code/claude-code-settings.json" ]; then
            content_stable_cp "$CODEGEN_DIR/templates/generated/claude-code/claude-code-settings.json" "$CLAUDE_SETTINGS_FILE"
            echo "   ✅ Claude Code settings installed at: $CLAUDE_SETTINGS_FILE"
        fi

        echo ""
        echo "🚀 Setting up Claude Code hooks..."

        if [ -d "$CODEGEN_DIR/harnesses/claude/hooks" ]; then
            mkdir -p "$CLAUDE_SETTINGS_DIR/hooks"
            for hook_file in "$CODEGEN_DIR/harnesses/claude/hooks"/*.sh; do
                if [ -f "$hook_file" ]; then
                    hook_name=$(basename "$hook_file")
                    content_stable_cp "$hook_file" "$CLAUDE_SETTINGS_DIR/hooks/$hook_name"
                    chmod +x "$CLAUDE_SETTINGS_DIR/hooks/$hook_name"
                    echo "   ✅ ${hook_name} hook installed at: $CLAUDE_SETTINGS_DIR/hooks/$hook_name"
                fi
            done

            # Prune orphan hooks
            if [ -d "$CLAUDE_SETTINGS_DIR/hooks" ]; then
                for installed_hook in "$CLAUDE_SETTINGS_DIR/hooks"/*.sh; do
                    [ -f "$installed_hook" ] || continue
                    hook_basename=$(basename "$installed_hook")
                    if [ ! -f "$CODEGEN_DIR/harnesses/claude/hooks/$hook_basename" ]; then
                        rm -f "$installed_hook"
                        echo "   Removed orphan hook: $hook_basename"
                    fi
                done
            fi

            # Install hooks lib
            if [ -d "$CODEGEN_DIR/harnesses/claude/hooks/lib" ]; then
                mkdir -p "$CLAUDE_SETTINGS_DIR/hooks/lib"
                for lib_file in "$CODEGEN_DIR/harnesses/claude/hooks/lib"/*; do
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

        if [ -d "$CODEGEN_DIR/harnesses/claude/commands" ]; then
            for cmd_file in "$CODEGEN_DIR/harnesses/claude/commands"/*.md; do
                if [ -f "$cmd_file" ]; then
                    cmd_name=$(basename "$cmd_file")
                    content_stable_cp "$cmd_file" "$CLAUDE_COMMANDS_DIR/$cmd_name"
                    echo "   ✅ Installed command: /${cmd_name%.md}"
                    CURRENT_COMMANDS+=("$cmd_name")
                fi
            done
        fi

        # Install generated commands (from .j2 templates rendered by generate.sh).
        if [ -d "$CODEGEN_DIR/templates/generated/claude-code/commands" ]; then
            for cmd_file in "$CODEGEN_DIR/templates/generated/claude-code/commands"/*.md; do
                if [ -f "$cmd_file" ]; then
                    cmd_name=$(basename "$cmd_file")
                    content_stable_cp "$cmd_file" "$CLAUDE_COMMANDS_DIR/$cmd_name"
                    echo "   ✅ Installed command (generated): /${cmd_name%.md}"
                    CURRENT_COMMANDS+=("$cmd_name")
                fi
            done
        fi

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

        printf '%s\n' "${CURRENT_COMMANDS[@]}" >"$COMMANDS_MANIFEST"

        # Install Claude sub agents
        echo "   🤖 Installing Claude sub agents..."
        CLAUDE_AGENTS_DIR="$CLAUDE_SETTINGS_DIR/agents"
        mkdir -p "$CLAUDE_AGENTS_DIR"

        AGENTS_MANIFEST="$CLAUDE_AGENTS_DIR/.installed-by-ocg"
        CURRENT_AGENTS=()

        # One-time migration: union per-stack manifests into single manifest.
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

        printf '%s\n' "${CURRENT_AGENTS[@]+"${CURRENT_AGENTS[@]}"}" >"$AGENTS_MANIFEST"

        # Install required dependencies (claude-specific)
        echo ""
        echo "🚀 Installing required dependencies..."

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
                if ! yq --version 2>&1 | grep -qi mikefarah; then
                    echo "   ❌ installed yq is not mikefarah/yq (apt python-yq is incompatible) — install from https://github.com/mikefarah/yq" >&2
                    exit 1
                fi
                echo "   ✅ yq installed"
            else
                echo "Warning: yq installation not supported on this OS. Install manually: https://github.com/mikefarah/yq"
            fi
        else
            echo "   ✅ yq already installed"
        fi

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

        # Determine shell rc file
        if [ "$SHELL" = "/bin/zsh" ] || [ "$SHELL" = "/usr/bin/zsh" ]; then
            RC_FILE="$HOME/.zshrc"
        else
            RC_FILE="$HOME/.bashrc"
        fi

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

        echo ""
        echo "🚀 Setting up autocompletion..."

        if grep -q "bash_completion.sh" "$RC_FILE" 2>/dev/null; then
            echo "   ⚠️  Completion already appears to be set up in $RC_FILE"
        else
            echo "" >>"$RC_FILE"
            echo "# Optimum Codegen autocompletion" >>"$RC_FILE"
            echo "source \"$CODEGEN_DIR/bash_completion.sh\"" >>"$RC_FILE"
            echo "   ✅ Added autocompletion to $RC_FILE"
        fi

        # De-register legacy aliases (idempotent)
        for _legacy_alias in claude-build claude-design claude-debug; do
            if grep -q "alias ${_legacy_alias}=" "$RC_FILE" 2>/dev/null; then
                _TEMP_FILE=$(mktemp)
                grep -v "^# Optimum Codegen ${_legacy_alias} alias$" "$RC_FILE" |
                    grep -v "^alias ${_legacy_alias}=" >"$_TEMP_FILE"
                if ! cmp -s "$RC_FILE" "$_TEMP_FILE"; then
                    mv "$_TEMP_FILE" "$RC_FILE"
                else
                    rm -f "$_TEMP_FILE"
                fi
                echo "   🗑️  Removed legacy ${_legacy_alias} alias from $RC_FILE"
            fi
        done

        # Remove legacy claude-design binary (idempotent)
        if [ -f "$INSTALL_DIR/claude-design" ]; then
            rm -f "$INSTALL_DIR/claude-design"
            echo "   Removed legacy: $INSTALL_DIR/claude-design"
        fi

        echo ""
        echo "🚀 Setting up Claude Code bash environment..."
        echo "🤖 Installing Claude Code..."
        hash -r 2>/dev/null || true
        if command -v claude >/dev/null 2>&1; then
            echo "   ✅ Claude Code already installed"
        else
            curl -fsSL https://claude.ai/install.sh | bash
            echo "   ✅ Claude Code installed"
        fi
        ;;

    pi)
        # ── Pi-specific: agents ───────────────────────────────────────────────
        echo "🔧 Setting up Pi configuration..."

        mkdir -p "$HOME/.pi/agent/agents"

        echo "   🤖 Installing Pi agents..."
        CURRENT_PI_AGENTS=()
        if [ -d "$CODEGEN_DIR/templates/generated/pi/agent" ]; then
            for agent_file in "$CODEGEN_DIR/templates/generated/pi/agent"/*.md; do
                if [ -f "$agent_file" ]; then
                    agent_name=$(basename "$agent_file")
                    content_stable_cp "$agent_file" "$HOME/.pi/agent/agents/$agent_name"
                    echo "   ✅ Installed Pi agent: ${agent_name%.md}"
                    CURRENT_PI_AGENTS+=("$agent_name")
                fi
            done
        fi
        if [ ${#CURRENT_PI_AGENTS[@]} -eq 0 ]; then
            echo "   ⚠️  Skipping Pi agent prune — install set is empty (generator may have failed)"
        else
            for installed_agent in "$HOME/.pi/agent/agents"/*.md; do
                [ -f "$installed_agent" ] || continue
                agent_basename=$(basename "$installed_agent")
                still_present=false
                for cur in "${CURRENT_PI_AGENTS[@]}"; do
                    [ "$cur" = "$agent_basename" ] && still_present=true && break
                done
                if [ "$still_present" = "false" ]; then
                    rm -f "$installed_agent"
                    echo "   🗑️  Removed stale Pi agent: ${agent_basename%.md}"
                fi
            done
        fi

        # Auto-trust nested .mise.toml to prevent mise from blocking with an interactive trust prompt.
        if command -v mise >/dev/null 2>&1; then
            mise trust "$CODEGEN_DIR/harnesses/pi/pi-extensions/enforcement/.mise.toml" >/dev/null 2>&1 || true
        fi

        # Install pi extensions — npm install runtime deps (no tsc; pi loads .ts via jiti)
        # askuserquestion: peerDeps only, no runtime deps — skip npm install
        # subagents + web-utils: have runtime dependencies that need node_modules
        echo "   📦 Installing Pi extension dependencies..."
        PI_EXTENSIONS_DIR="$CODEGEN_DIR/harnesses/pi/pi-extensions"
        for _ext_dir in "$PI_EXTENSIONS_DIR/subagents" "$PI_EXTENSIONS_DIR/web-utils"; do
            if [ -d "$_ext_dir" ] && [ -f "$_ext_dir/package.json" ]; then
                _ext_name=$(basename "$_ext_dir")
                echo "   Installing deps for pi-extension: $_ext_name..."
                _pi_ext_install_failed=0
                (cd "$_ext_dir" && mise exec -- npm install --prefer-offline) 2>&1 || _pi_ext_install_failed=1
                if [ "$_pi_ext_install_failed" -eq 1 ]; then
                    echo "❌ pi-extension npm install failed: $_ext_name — extension ships broken" >&2
                    exit 1
                fi
                echo "   ✅ pi-extension deps installed: $_ext_name"
            fi
        done

        # Install pi prompts — full generated set with mkdir + prune
        PROMPTS_DST="$HOME/.pi/agent/prompts"
        PROMPTS_SRC="$CODEGEN_DIR/templates/generated/pi/prompts"
        mkdir -p "$PROMPTS_DST"
        CURRENT_PI_PROMPTS=()
        if [ -d "$PROMPTS_SRC" ]; then
            echo "   Installing Pi prompts into $PROMPTS_DST..."
            for _prompt_file in "$PROMPTS_SRC"/*.md; do
                [ -f "$_prompt_file" ] || continue
                _prompt_name=$(basename "$_prompt_file")
                content_stable_cp "$_prompt_file" "$PROMPTS_DST/$_prompt_name"
                echo "   ✅ Installed Pi prompt: $_prompt_name"
                CURRENT_PI_PROMPTS+=("$_prompt_name")
            done
        fi
        # Prune stale prompts
        if [ ${#CURRENT_PI_PROMPTS[@]} -eq 0 ]; then
            echo "   ⚠️  Skipping Pi prompt prune — install set is empty (generator may have failed)"
        else
            for _installed_prompt in "$PROMPTS_DST"/*.md; do
                [ -f "$_installed_prompt" ] || continue
                _prompt_basename=$(basename "$_installed_prompt")
                _still_present=false
                for _cur in "${CURRENT_PI_PROMPTS[@]}"; do
                    [ "$_cur" = "$_prompt_basename" ] && _still_present=true && break
                done
                if [ "$_still_present" = "false" ]; then
                    rm -f "$_installed_prompt"
                    echo "   🗑️  Removed stale Pi prompt: $_prompt_basename"
                fi
            done
        fi

        echo "   ✅ Pi configuration complete"
        ;;
    esac

    # ── Manifest-driven: launchers + completions (all harnesses) ─────────────
    echo ""
    echo "🚀 Installing $_harness launchers..."
    mkdir -p "$INSTALL_DIR"

    CURRENT_LAUNCHERS=()
    while IFS=' ' read -r _src _dest_name; do
        _dest="$INSTALL_DIR/$_dest_name"
        content_stable_cp "$CODEGEN_DIR/$_src" "$_dest"
        chmod +x "$_dest"
        echo "   ✅ Installed launcher: $_dest_name → $_dest"
        CURRENT_LAUNCHERS+=("$_dest_name")
    done < <(manifest_launchers "$_harness")

    # Prune stale launchers for this harness (prefix = harness name + dash)
    if [ ${#CURRENT_LAUNCHERS[@]} -gt 0 ]; then
        for _installed_launcher in "$INSTALL_DIR/${_harness}-"*; do
            [ -f "$_installed_launcher" ] || continue
            _launcher_basename=$(basename "$_installed_launcher")
            _launcher_still_present=false
            for _cur_launcher in "${CURRENT_LAUNCHERS[@]}"; do
                [ "$_cur_launcher" = "$_launcher_basename" ] && _launcher_still_present=true && break
            done
            if [ "$_launcher_still_present" = "false" ]; then
                rm -f "$_installed_launcher"
                echo "   🗑️  Removed stale launcher: $_launcher_basename"
            fi
        done
    fi

    echo ""
    echo "🚀 Installing $_harness zsh completions..."
    if [ -n "$ZSH_COMPLETION_DST" ]; then
        while IFS= read -r _comp; do
            content_stable_cp "$CODEGEN_DIR/harnesses/$_harness/$_comp" "$ZSH_COMPLETION_DST/$_comp"
            echo "   Installed zsh completion: $ZSH_COMPLETION_DST/$_comp"
        done < <(manifest_completions "$_harness")
    else
        echo "WARNING: no writable zsh completion dir found (tried ${ZSH_COMPLETION_DIRS[*]}); skipping $_harness completion install" >&2
    fi

done # harness loop

# Create OCG config directory
mkdir -p "$HOME/.ocg"

if [ ! -f "$HOME/.ocg/config.json" ]; then
    # If only one harness was selected, use it as the default without prompting.
    # Otherwise prompt the user among the selected harnesses.
    if [ ${#HARNESSES[@]} -eq 1 ]; then
        default_agent="${HARNESSES[0]}"
    else
        if [ -n "${OCG_DEFAULT_AGENT:-}" ]; then
            if ! harness_enabled "$OCG_DEFAULT_AGENT"; then
                echo "❌ OCG_DEFAULT_AGENT=$OCG_DEFAULT_AGENT not among installed harnesses (${HARNESSES[*]})"
                exit 1
            fi
            default_agent="$OCG_DEFAULT_AGENT"
        elif [ "${OCG_NONINTERACTIVE:-}" = "1" ]; then
            echo "❌ OCG_NONINTERACTIVE=1 set but OCG_DEFAULT_AGENT unset and multiple harnesses installed (${HARNESSES[*]})"
            exit 1
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
            if [[ ! -t 0 ]]; then
                echo "❌ install.sh needs a TTY for agent selection; set OCG_DEFAULT_AGENT=<claude|pi> for non-interactive installs" >&2
                exit 1
            fi
            read -p "   Choose [1-${#HARNESSES[@]}]: " choice
            if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#HARNESSES[@]} ]; then
                default_agent="${HARNESSES[$((choice - 1))]}"
            else
                default_agent="${HARNESSES[0]}"
            fi
        fi
    fi

    claude_enabled=false
    pi_enabled=false
    harness_enabled claude && claude_enabled=true
    harness_enabled pi && pi_enabled=true

    cat >"$HOME/.ocg/config.json" <<EOF
{
    "default_agent": "$default_agent",
    "agents": {
        "claude": { "enabled": $claude_enabled },
        "pi": { "enabled": $pi_enabled }
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

# Format codegen shared dir after install finishes regenerating files
# Resolve prettier's real CJS entry and run via a non-shim node binary.
# Resolving through the mise shim triggers trust checks when HOME is changed in tests;
# scanning PATH for a non-shim node entry avoids mise entirely.
# Non-fatal: formatting is cosmetic; installation succeeds even if prettier can't run.
if [ -d "$CODEGEN_DIR/shared" ]; then
    _prettier_cjs="$CODEGEN_DIR/node_modules/prettier/bin/prettier.cjs"
    if [ -f "$_prettier_cjs" ]; then
        # Find a real (non-shim) node binary by scanning PATH entries.
        _real_node=""
        _old_IFS="$IFS"
        IFS=:
        for _dir in $PATH; do
            IFS="$_old_IFS"
            if [ -x "$_dir/node" ] && printf '%s' "$_dir" | grep -qv "shims"; then
                _real_node="$_dir/node"
                break
            fi
            IFS=:
        done
        IFS="$_old_IFS"
        # Fallback: use the shim (may fail with trust error but non-fatal)
        if [ -z "$_real_node" ]; then
            _real_node="$(command -v node 2>/dev/null || true)"
        fi
        if [ -n "$_real_node" ] && [ -x "$_real_node" ]; then
            _prettier_err="$(mktemp)"
            if ! "$_real_node" "$_prettier_cjs" -w --log-level error "$CODEGEN_DIR/shared" 2>"$_prettier_err"; then
                echo "⚠️  prettier failed to format shared/ (non-fatal) — output below:" >&2
                cat "$_prettier_err" >&2
            fi
            rm -f "$_prettier_err"
        fi
    fi
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
