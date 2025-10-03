#!/bin/bash
# Template Generation Script
# Generates AI tool-specific templates from shared Jinja2 templates

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATES_DIR="$(dirname "$SCRIPT_DIR")"
GENERATOR_DIR="$SCRIPT_DIR"

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${BLUE}ℹ️  $1${NC}"
}

log_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

log_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

# Simple template processor using external Python script
process_template() {
    local template_file="$1"
    local tool="$2"
    local tool_config="$3"

    if [ ! -f "$template_file" ]; then
        echo "Template file not found: $template_file" >&2
        return 1
    fi

    # Extract tool configuration variables
    local tool_name=$(echo "$tool_config" | grep "^    name:" | sed 's/.*name: "\(.*\)".*/\1/')
    local yaml_frontmatter=$(echo "$tool_config" | grep "yaml_frontmatter:" | sed 's/.*yaml_frontmatter: \(.*\)/\1/')

    # Use external Python script for template processing
    "$GENERATOR_DIR/process_template.py" "$template_file" "$tool_name" "$yaml_frontmatter"
}

# Copy non-template files
copy_file() {
    local source_file="$1"
    local output_file="$2"

    if [ ! -f "$source_file" ]; then
        echo "Source file not found: $source_file" >&2
        return 1
    fi

    cp "$source_file" "$output_file"
}

# Generate templates for a specific tool
generate_for_tool() {
    local tool="$1"

    log_info "Generating templates for $tool..."

    # Read tool configuration
    local tool_config=$(grep -A 10 "^  $tool:" "$GENERATOR_DIR/config.yaml")
    if [ -z "$tool_config" ]; then
        echo "❌ Tool configuration not found: $tool" >&2
        return 1
    fi

    # Create output directory
    local output_dir="$TEMPLATES_DIR/generated/$tool"
    if [ "$tool" = "claude" ]; then
        output_dir="$TEMPLATES_DIR/generated/claude-code"
    fi

    # Create different subdir for Claude Code vs OpenCode
    if [ "$tool" = "claude" ]; then
        mkdir -p "$output_dir/commands" "$output_dir/agents"
    else
        mkdir -p "$output_dir/commands" "$output_dir/agent"
    fi

    # Generate or copy settings file
    if [ "$tool" = "claude" ]; then
        # Claude Code uses a static settings file
        if [ -f "$TEMPLATES_DIR/claude-code-settings.json" ]; then
            copy_file "$TEMPLATES_DIR/claude-code-settings.json" "$output_dir/claude-code-settings.json"
            log_success "Generated claude-code-settings.json"
        fi
    else
        # OpenCode uses a static config file
        if [ -f "$TEMPLATES_DIR/.opencode.json" ]; then
            copy_file "$TEMPLATES_DIR/.opencode.json" "$output_dir/.opencode.json"
            log_success "Generated .opencode.json"
        fi
    fi

    # Generate command templates from .j2 files only
    if [ -d "$TEMPLATES_DIR/shared/commands" ]; then
        for template_file in "$TEMPLATES_DIR/shared/commands"/*.j2; do
            if [ -f "$template_file" ]; then
                local base_name=$(basename "$template_file" .j2)
                process_template "$template_file" "$tool" "$tool_config" >"$output_dir/commands/$base_name"
                log_success "Generated command: $base_name"
            fi
        done
    fi

    # Generate subagent templates
    if [ -d "$TEMPLATES_DIR/shared/subagents" ]; then
        for template_file in "$TEMPLATES_DIR/shared/subagents"/*.j2; do
            if [ -f "$template_file" ]; then
                local base_name=$(basename "$template_file" .j2)
                # Output to different dirs for Claude Code vs OpenCode
                if [ "$tool" = "claude" ]; then
                    process_template "$template_file" "$tool" "$tool_config" >"$output_dir/agents/$base_name"
                else
                    process_template "$template_file" "$tool" "$tool_config" >"$output_dir/agent/$base_name"
                fi
                log_success "Generated subagent: $base_name"
            fi
        done
    fi

    log_success "Template generation complete for $tool"
}

# Main execution
main() {
    local tool="${1:-all}"

    echo "🚀 OCG Template Generator"
    echo "========================"
    echo ""

    # Check for Python3
    if ! command -v python3 >/dev/null 2>&1; then
        echo "❌ Python3 is required for template processing"
        echo "   Please install Python3 and try again"
        exit 1
    fi

    if [ "$tool" = "all" ]; then
        generate_for_tool "claude"
        echo ""
        generate_for_tool "opencode"
    elif [ "$tool" = "claude" ] || [ "$tool" = "opencode" ]; then
        generate_for_tool "$tool"
    else
        echo "❌ Unknown tool: $tool"
        echo "Usage: $0 [claude|opencode|all]"
        exit 1
    fi

    echo ""
    log_success "All template generation complete!"
}

# Run main function with all arguments
main "$@"
