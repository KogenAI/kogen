#!/usr/bin/env bash
# templates/generator/generate.sh — unified manifest-driven generator.
#
# Absorbs generate-claude.sh + generate-pi.sh (deleted).
# Reads harnesses/<harness>/manifest.yaml.
# Regenerates *-system-prompt.txt from tools-header + shared body (byte-stable).
#
# Usage:
#   generate.sh claude          — generate claude harness only
#   generate.sh pi              — generate pi harness only
#   generate.sh claude pi       — generate both (default from make install)
#
# Output: templates/generated/<harness>/ (same as legacy generators).
# Byte-identity guaranteed: output identical to former generate-{claude,pi}.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATES_DIR="$(dirname "$SCRIPT_DIR")"
CODEGEN_DIR="$(dirname "$TEMPLATES_DIR")"
export CODEGEN_DIR

# Source manifest helpers.
# shellcheck source=templates/generator/manifest-lib.sh
source "$SCRIPT_DIR/manifest-lib.sh"

# ─── Internal helpers (formerly in generate-claude.sh) ───────────────────────

_log_info() { echo -e "\033[0;34mℹ️  $1\033[0m"; }
_log_success() { echo -e "\033[0;32m✅ $1\033[0m"; }

# process_template <template_file> <tool> [yaml_frontmatter]
# Calls process_template.py which handles Jinja2 rendering.
_process_template() {
    local template_file="$1"
    local tool="$2"
    local yaml_frontmatter="${3:-false}"

    if [ ! -f "$template_file" ]; then
        echo "Template file not found: $template_file" >&2
        return 1
    fi

    if [ "$tool" = "claude" ]; then
        "$SCRIPT_DIR/process_template.py" --config "$SCRIPT_DIR/config.yaml" \
            "$template_file" "$tool" "$yaml_frontmatter"
    else
        "$SCRIPT_DIR/process_template.py" "$template_file" "$tool" "$yaml_frontmatter"
    fi
}

# _ensure_pyyaml: auto-install pyyaml if missing (pi generator requirement).
_ensure_pyyaml() {
    if ! python3 -c "import yaml" 2>/dev/null; then
        echo "   Installing pyyaml..."
        python3 -m pip install --user --quiet pyyaml --break-system-packages 2>/dev/null ||
            python3 -m pip install --user --quiet pyyaml 2>/dev/null ||
            {
                echo "❌ Failed to install pyyaml. Run: pip3 install pyyaml" >&2
                exit 1
            }
    fi
}

# ─── Per-harness generators ───────────────────────────────────────────────────

_generate_claude() {
    _log_info "Generating templates for claude..."

    local output_dir="$TEMPLATES_DIR/generated/claude-code"

    if [ -z "${OUTPUT_DIR:-}" ]; then
        mkdir -p "$output_dir/commands" "$output_dir/agents"
    fi

    # Copy settings file
    if [ -z "${OUTPUT_DIR:-}" ]; then
        local harnesses_claude_dir="$CODEGEN_DIR/harnesses/claude"
        if [ -f "$harnesses_claude_dir/claude-code-settings.json" ]; then
            cp "$harnesses_claude_dir/claude-code-settings.json" "$output_dir/claude-code-settings.json"
            _log_success "Generated claude-code-settings.json"
        fi

        # Generate command templates from .j2 files only
        if [ -d "$CODEGEN_DIR/harnesses/claude/commands" ]; then
            for template_file in "$CODEGEN_DIR/harnesses/claude/commands"/*.j2; do
                if [ -f "$template_file" ]; then
                    local base_name
                    base_name=$(basename "$template_file" .j2)
                    _process_template "$template_file" claude true >"$output_dir/commands/$base_name"
                    _log_success "Generated command: $base_name"
                fi
            done
        fi
    fi

    # Generate subagent templates
    local subagents_root="$CODEGEN_DIR/shared/subagents"
    local subdirs=("$subagents_root/shared" "$subagents_root/phoenix" "$subagents_root/static")
    local agents_subdir="$output_dir/agents"

    if [ -n "${OUTPUT_DIR:-}" ]; then
        agents_subdir="$OUTPUT_DIR"
        mkdir -p "$agents_subdir"
    fi

    for subdir in "${subdirs[@]}"; do
        if [ -d "$subdir" ]; then
            for template_file in "$subdir"/*.j2; do
                if [ -f "$template_file" ]; then
                    local base_name
                    base_name=$(basename "$template_file" .j2)
                    _process_template "$template_file" claude true >"$agents_subdir/$base_name"
                    _log_success "Generated subagent: $base_name"
                fi
            done
        fi
    done

    _log_success "Template generation complete for claude"
    echo ""
    _log_success "All template generation complete!"
}

_generate_pi() {
    _ensure_pyyaml

    local output_agents_dir="$TEMPLATES_DIR/generated/pi/agent"
    local output_prompts_dir="$TEMPLATES_DIR/generated/pi/prompts"

    mkdir -p "$output_agents_dir"
    mkdir -p "$output_prompts_dir"

    echo "🚀 Generating Pi command prompts..."

    local shared_commands_dir="$CODEGEN_DIR/harnesses/claude/commands"
    if [ -d "$shared_commands_dir" ]; then
        for cmd_file in "$shared_commands_dir"/*.md; do
            if [ -f "$cmd_file" ]; then
                local cmd_name
                cmd_name=$(basename "$cmd_file")
                cp "$cmd_file" "$output_prompts_dir/$cmd_name"
                echo "   Copied command: $cmd_name"
            fi
        done
    fi

    echo "🚀 Generating Pi Markdown agents..."

    local subagents_root="$CODEGEN_DIR/shared/subagents"
    local subdirs=("$subagents_root/shared" "$subagents_root/phoenix" "$subagents_root/static")

    for subdir in "${subdirs[@]}"; do
        [ -d "$subdir" ] || continue
        for template_file in "$subdir"/*.md.j2; do
            [ -f "$template_file" ] || continue
            local base_name role_name output_file
            base_name=$(basename "$template_file" .j2) # e.g. planner.md
            role_name="${base_name%.md}"               # e.g. planner
            output_file="$output_agents_dir/${role_name}.md"

            echo "   Generating: ${role_name}.md"
            python3 "$SCRIPT_DIR/process_template.py" \
                "$template_file" pi false >"$output_file"
            echo "   ✅ Written: $(basename "$output_file")"
        done
    done

    echo ""
    echo "✅ Pi generation complete!"
    echo "   Agents: $output_agents_dir"
    echo "   Prompts: $TEMPLATES_DIR/generated/pi/prompts"
}

# ─── Main ─────────────────────────────────────────────────────────────────────

if [ $# -eq 0 ]; then
    echo "Usage: generate.sh <harness> [<harness> ...]" >&2
    echo "  harness: claude | pi" >&2
    exit 1
fi

# Check for Python3
if ! command -v python3 >/dev/null 2>&1; then
    echo "❌ Python3 is required for template processing" >&2
    exit 1
fi

echo "🚀 OCG Template Generator"
echo "========================"
echo ""

for harness in "$@"; do
    case "$harness" in
    claude)
        _generate_claude
        ;;
    pi)
        _generate_pi
        ;;
    *)
        echo "generate.sh: unknown harness '$harness' (expected: claude | pi)" >&2
        exit 1
        ;;
    esac

    # Regenerate *-system-prompt.txt from tools-header + shared body (byte-stable).
    manifest_regenerate_prompts "$harness"

    echo "   ✅ $harness generation complete"
    echo ""
done

echo "✅ generate.sh: all harnesses done"
