#!/bin/bash

# Generate usage rules for Elixir dependencies from mix.exs

set -e

# Track background jobs for cleanup
declare -a BG_PIDS=()

# Cleanup handler for Ctrl+C
cleanup() {
    echo ""
    echo "⚠️  Interrupted! Killing background jobs..."
    for pid in "${BG_PIDS[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
    exit 130
}

trap cleanup INT TERM

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source configuration and utilities
source "$SCRIPT_DIR/config.sh"
source "$SCRIPT_DIR/utils.sh"

# Use OCG_CONTEXT_DIR environment variable or fallback
if [ -z "$OCG_CONTEXT_DIR" ]; then
    echo "❌ Error: OCG_CONTEXT_DIR environment variable not set"
    echo "Please run 'ocg setup' first or set OCG_CONTEXT_DIR manually"
    exit 1
fi

USAGE_RULES_DIR="$OCG_CONTEXT_DIR/usage_rules"

# Ensure usage rules directory exists
mkdir -p "$USAGE_RULES_DIR"

# Built-in Elixir/Erlang applications that don't need documentation
BUILTIN_DEPS="logger crypto ssl public_key inets mnesia runtime_tools observer sasl tools eex iex mix ex_unit"

# Function to check if dependency is built-in
is_builtin() {
    local dep="$1"
    echo "$BUILTIN_DEPS" | grep -qw "$dep"
}

# Function to extract dependencies with versions from mix.lock
extract_dependencies() {
    local mix_file="$1"
    local mix_dir=$(dirname "$mix_file")
    local lock_file="$mix_dir/mix.lock"

    if [ ! -f "$mix_file" ]; then
        echo "❌ Error: mix.exs not found at $mix_file"
        exit 1
    fi

    # First, get list of dependencies from mix.exs
    local deps_from_mix=$(grep -E 'defp [a-z_]*deps do' -A 1000 "$mix_file" |
        grep -E '^\s*\{:' |
        sed 's/.*{:\([a-z_0-9]*\).*/\1/' |
        sort -u)

    # Then extract exact versions from mix.lock
    if [ ! -f "$lock_file" ]; then
        echo "❌ Error: mix.lock not found at $lock_file"
        echo "Run 'mix deps.get' to generate mix.lock first"
        exit 1
    fi

    # Extract versions from mix.lock
    # Hex format: "dep_name": {:hex, :dep_name, "1.2.3", ...}
    # Git format: "dep_name": {:git, "url", "sha", [tag: "v1.2.3", ...]}
    while read -r dep; do
        if ! is_builtin "$dep"; then
            local line=$(grep "\"$dep\":" "$lock_file")
            local version=""

            # Check if it's a hex package
            if echo "$line" | grep -q ":hex,"; then
                # Extract hex version: "1.2.3"
                version=$(echo "$line" | grep -oE '"[0-9]+\.[0-9]+(\.[0-9]+(-[a-z0-9.]+)?)?"' | head -1 | tr -d '"')
            elif echo "$line" | grep -q ":git,"; then
                # Extract git tag if present: [tag: "v2.1.1", ...]
                local tag=$(echo "$line" | grep -oE 'tag: "[^"]*"' | cut -d'"' -f2)
                if [ -n "$tag" ]; then
                    # Remove 'v' prefix if present
                    version=$(echo "$tag" | sed 's/^v//')
                else
                    # No tag, use short SHA (first 7 chars of commit hash)
                    local sha=$(echo "$line" | grep -oE '"[a-f0-9]{40}"' | head -1 | tr -d '"' | cut -c1-7)
                    if [ -n "$sha" ]; then
                        version="git-$sha"
                    fi
                fi
            fi

            if [ -z "$version" ]; then
                version="~no_version~"
            fi

            echo "${dep}:${version}"
        fi
    done <<<"$deps_from_mix" | sort -u
}

# Function to check if usage rule needs updating
usage_rule_needs_update() {
    local dep_name="$1"
    local version="$2"

    # Sanitize version for filename (replace special chars with dash)
    local version_safe=$(echo "$version" | sed 's/[^a-zA-Z0-9.]/-/g')
    local file="$USAGE_RULES_DIR/${dep_name}-${version_safe}.md"

    if [ ! -f "$file" ]; then
        return 0 # Needs generation
    fi

    return 1 # File exists, skip
}

# Function to generate usage rule from hexdocs
generate_usage_rule() {
    local dep_name="$1"
    local version="$2"

    # Sanitize version for filename (replace special chars with dash)
    local version_safe=$(echo "$version" | sed 's/[^a-zA-Z0-9.]/-/g')
    local output_file="$USAGE_RULES_DIR/${dep_name}-${version_safe}.md"

    echo "🔍 Generating usage rule for $dep_name..."

    # Use hexdocs URL
    local hexdocs_url="https://hexdocs.pm/$dep_name/"

    echo "📝 Generating documentation for $dep_name from hexdocs..."
    echo "⏳ This may take a moment..."

    # Create a comprehensive prompt for generating usage rules
    local prompt_file=$(mktemp)

    # Check if this is a framework that needs multi-file splitting
    local is_framework=false
    case "$dep_name" in
    phoenix | ecto | phoenix_live_view | absinthe | ash | nerves | broadway | oban | membrane)
        is_framework=true
        ;;
    esac

    # Let Claude determine library size and generate files
    if [ "$is_framework" = true ]; then
        cat >"$prompt_file" <<'PROMPT_EOF'
Visit hexdocs_url_placeholder and analyze the documentation to create usage rules.

CRITICAL: You have Write tool access. Use it to create files directly in output_dir_placeholder.

This is a FRAMEWORK library. Split documentation into MULTIPLE SEPARATE FILES:

1. MAIN INDEX FILE: output_dir_placeholder/dep_name_placeholder-version_placeholder.md
   Content:
   # dep_name_placeholder

   [2-3 paragraph overview of what the library does]

   ## Quick Start
   [Basic installation and minimal example]

   ## Documentation Sections
   - [Topic 1 Name](dep_name_placeholder-version_placeholder-topic1.md)
   - [Topic 2 Name](dep_name_placeholder-version_placeholder-topic2.md)
   - [Topic 3 Name](dep_name_placeholder-version_placeholder-topic3.md)
   ... (5-8 major topics based on guide structure)

   ---
   **Version:** version_placeholder
   **Source:** [hexdocs.pm/dep_name_placeholder](hexdocs_url_placeholder)
   **Generated:** date_placeholder

2. SEPARATE TOPIC FILES: output_dir_placeholder/dep_name_placeholder-version_placeholder-[topic].md
   One file per major topic (5-8 files total).

   Each file structure:
   # dep_name_placeholder - [Topic Name]

   [Comprehensive content extracted from hexdocs guides]
   [Include code examples, patterns, best practices]
   [100-250 lines per file]

   ---
   [← Back to main](dep_name_placeholder-version_placeholder.md)
   **Version:** version_placeholder

MANDATORY REQUIREMENTS:
- Use Write tool to create files directly in output_dir_placeholder
- NO conversational text before/after - ONLY create the files
- Extract actual content from hexdocs guides (not API docs)
- Determine 5-8 logical topic splits based on guide structure
- Each section file should be comprehensive (100-250 lines)
- After creating files, output ONLY: "Created: [list of filenames]"
PROMPT_EOF
    else
        cat >"$prompt_file" <<'PROMPT_EOF'
Visit hexdocs_url_placeholder and create usage documentation.

CRITICAL: You have Write tool access. Use it to create files directly in output_dir_placeholder.

Create ONE COMPREHENSIVE FILE: output_dir_placeholder/dep_name_placeholder-version_placeholder.md

Structure:
# dep_name_placeholder
[Overview]
## Quick Start
[Installation and basic usage]
## Core Concepts
[Main features and patterns]
## Configuration
[How to configure]
## Best Practices
[Common patterns and recommendations]
---
**Version:** version_placeholder
**Source:** [hexdocs.pm/dep_name_placeholder](hexdocs_url_placeholder)
**Generated:** date_placeholder

MANDATORY REQUIREMENTS:
- Use Write tool to create the file directly in output_dir_placeholder
- NO conversational text before/after - ONLY create the file
- Extract actual content from hexdocs guides (not API docs)
- Keep comprehensive but concise (100-300 lines)
- After creating file, output ONLY: "Created: [filename]"
PROMPT_EOF
    fi

    # Replace placeholders
    local version_display="$version"
    if [ "$version" = "~no_version~" ]; then
        version_display="latest"
    fi

    sed -i.bak \
        -e "s|hexdocs_url_placeholder|$hexdocs_url|g" \
        -e "s|dep_name_placeholder|$dep_name|g" \
        -e "s|version_placeholder|$version_display|g" \
        -e "s|date_placeholder|$(date '+%Y-%m-%d')|g" \
        -e "s|output_dir_placeholder|$USAGE_RULES_DIR|g" \
        "$prompt_file"
    rm -f "${prompt_file}.bak"

    # Load AI assistant configuration
    CONFIG_FILE="$HOME/.ocg/config.json"
    if [ -n "$AGENT_OVERRIDE" ]; then
        case "$AGENT_OVERRIDE" in
        "claude" | "codex")
            AI_ASSISTANT="$AGENT_OVERRIDE"
            ;;
        *)
            echo "⚠️  Invalid agent '$AGENT_OVERRIDE'. Valid agents: claude, codex"
            if [ -f "$CONFIG_FILE" ]; then
                AI_ASSISTANT=$(jq -r '.default_agent // "claude"' "$CONFIG_FILE" 2>/dev/null || echo "claude")
            else
                AI_ASSISTANT="claude"
            fi
            ;;
        esac
    else
        if [ -f "$CONFIG_FILE" ]; then
            AI_ASSISTANT=$(jq -r '.default_agent // "claude"' "$CONFIG_FILE" 2>/dev/null || echo "claude")
        else
            AI_ASSISTANT="claude"
        fi
    fi

    # Use model override if provided, otherwise default to haiku
    if [ -n "$MODEL_OVERRIDE" ]; then
        case "$MODEL_OVERRIDE" in
        "haiku" | "sonnet" | "opus")
            MODEL="$MODEL_OVERRIDE"
            ;;
        *)
            echo "⚠️  Invalid model '$MODEL_OVERRIDE'. Valid models: haiku, sonnet, opus. Using default 'haiku'"
            MODEL="haiku"
            ;;
        esac
    else
        MODEL="haiku"
    fi

    # Try to use AI assistant to generate the content
    echo "🤖 Generating content with $AI_ASSISTANT ($MODEL)..."
    local temp_output=$(mktemp)

    # Try up to 3 times if AI generation fails
    local max_retries=3
    local retry=0
    local success=false

    while [ $retry -lt $max_retries ] && [ "$success" = false ]; do
        if "$SCRIPT_DIR/ai-agents/run-ai.sh" "$AI_ASSISTANT" "$MODEL" "$prompt_file" >"$temp_output" 2>/dev/null; then
            # Check if main file was created
            if [ -f "$output_file" ]; then
                # Check for additional section files (for large libraries)
                local section_files=$(ls "$USAGE_RULES_DIR/${dep_name}-${version_safe}"-*.md 2>/dev/null | grep -v "^$output_file$" | wc -l | tr -d ' ')

                if [ "$section_files" -gt 0 ]; then
                    echo "✅ Generated usage rules: $output_file + $section_files section files (version: $version_display)"
                else
                    echo "✅ Generated usage rule: $output_file (version: $version_display)"
                fi
                success=true
            else
                ((retry++))
                if [ $retry -lt $max_retries ]; then
                    echo "⚠️  File not created for $dep_name, retrying ($retry/$max_retries)..."
                    sleep 2
                else
                    echo "❌ Failed to generate usage rule for $dep_name after $max_retries attempts"
                    return 1
                fi
            fi
        else
            ((retry++))
            if [ $retry -lt $max_retries ]; then
                echo "⚠️  AI generation failed for $dep_name, retrying ($retry/$max_retries)..."
                sleep 2
            else
                echo "❌ Failed to generate usage rule for $dep_name after $max_retries attempts"
                return 1
            fi
        fi
    done

    # Clean up temporary files
    rm -f "$prompt_file" "$temp_output"
}

# Function to update existing usage rule
update_usage_rule() {
    local dep_name="$1"
    local version="$2"
    local version_display="$version"
    if [ "$version" = "~no_version~" ]; then
        version_display="latest"
    fi
    echo "ℹ️  Usage rule already exists for $dep_name (version: $version_display), skipping..."
}

# Parse command line arguments
MODEL_OVERRIDE=""
AGENT_OVERRIDE=""
while [[ $# -gt 0 ]]; do
    case $1 in
    --model | -m)
        MODEL_OVERRIDE="$2"
        shift 2
        ;;
    --agent | -a | --ai)
        AGENT_OVERRIDE="$2"
        shift 2
        ;;
    --help | -h)
        echo "Usage: ocg usage-rules [options]"
        echo "Options:"
        echo "  --model, -m <model>    AI model to use (haiku/sonnet/opus, default: haiku)"
        echo "  --agent, -a <name>     AI agent to use (default: from config)"
        echo ""
        echo "Examples:"
        echo "  ocg usage-rules"
        echo "  ocg usage-rules --model haiku"
        echo "  ocg usage-rules -m sonnet -a codex"
        exit 0
        ;;
    *)
        echo "Unknown option: $1"
        echo "Use --help for usage information"
        exit 1
        ;;
    esac
done

# Main function
main() {
    echo "🚀 OCG Usage Rules Generator"
    echo "=============================="

    # Display model being used
    local display_model="${MODEL_OVERRIDE:-haiku}"
    echo "🤖 Using AI model: $display_model"
    echo ""

    # Find mix.exs in current workspace or project root
    local mix_file
    if [ -f "$TARGET_REPO_PATH/mix.exs" ]; then
        mix_file="$TARGET_REPO_PATH/mix.exs"
    elif [ -f "mix.exs" ]; then
        mix_file="mix.exs"
    else
        echo "❌ Error: mix.exs not found in current directory or project root"
        exit 1
    fi

    echo "📂 Using mix.exs: $mix_file"
    echo "📁 Usage rules directory: $USAGE_RULES_DIR"
    echo ""

    # Extract dependencies
    local dependencies
    dependencies=$(extract_dependencies "$mix_file")

    if [ -z "$dependencies" ]; then
        echo "❌ No dependencies found in mix.exs"
        exit 1
    fi

    echo "📦 Found dependencies:"
    echo "$dependencies" | sed 's/^/   - /'
    echo ""

    # Process dependencies with throttled parallelism (max 5 concurrent)
    local new_rules=0
    local existing_rules=0
    local failed_rules=0
    local pids=()
    local temp_dir=$(mktemp -d)
    local max_concurrent=5
    local deps_to_generate=()

    # First pass: identify which deps need generation
    while IFS= read -r dep_with_version; do
        if [ -n "$dep_with_version" ]; then
            local dep_name=$(echo "$dep_with_version" | cut -d: -f1)
            local dep_version=$(echo "$dep_with_version" | cut -d: -f2)

            if usage_rule_needs_update "$dep_name" "$dep_version"; then
                deps_to_generate+=("$dep_with_version")
            else
                update_usage_rule "$dep_name" "$dep_version"
                ((existing_rules++))
            fi
        fi
    done <<<"$dependencies"

    # Second pass: generate with throttling
    local total_to_generate=${#deps_to_generate[@]}
    local current_index=0

    while [ $current_index -lt $total_to_generate ] || [ ${#pids[@]} -gt 0 ]; do
        # Start new jobs up to max_concurrent
        while [ ${#pids[@]} -lt $max_concurrent ] && [ $current_index -lt $total_to_generate ]; do
            local dep_with_version="${deps_to_generate[$current_index]}"
            local dep_name=$(echo "$dep_with_version" | cut -d: -f1)
            local dep_version=$(echo "$dep_with_version" | cut -d: -f2)
            (
                if generate_usage_rule "$dep_name" "$dep_version"; then
                    echo "success" >"$temp_dir/${dep_name}.status"
                else
                    echo "failed" >"$temp_dir/${dep_name}.status"
                fi
            ) &
            local new_pid=$!
            pids+=($new_pid)
            BG_PIDS+=($new_pid)
            ((current_index++))
        done

        # Wait for at least one job to complete
        if [ ${#pids[@]} -gt 0 ]; then
            wait -n "${pids[@]}" 2>/dev/null || true
            # Remove completed PIDs
            local new_pids=()
            for pid in "${pids[@]}"; do
                if kill -0 "$pid" 2>/dev/null; then
                    new_pids+=("$pid")
                fi
            done
            pids=("${new_pids[@]}")
        fi
    done

    # Count results
    for dep_with_version in "${deps_to_generate[@]}"; do
        local dep_name=$(echo "$dep_with_version" | cut -d: -f1)
        if [ -f "$temp_dir/${dep_name}.status" ]; then
            local status=$(cat "$temp_dir/${dep_name}.status")
            if [ "$status" = "success" ]; then
                ((new_rules++))
            else
                ((failed_rules++))
            fi
        else
            ((failed_rules++))
        fi
    done

    rm -rf "$temp_dir"

    echo ""
    echo "✅ Summary:"
    echo "   - New usage rules generated: $new_rules"
    echo "   - Existing usage rules found: $existing_rules"
    echo "   - Failed generations: $failed_rules"
    echo "   - Total dependencies processed: $((new_rules + existing_rules + failed_rules))"

    if [ $failed_rules -gt 0 ]; then
        echo ""
        echo "⚠️  Some dependencies failed to generate after 3 retries."
        echo "   These need to be generated from valid hexdocs content."
        echo "   Run the command again to retry, or check hexdocs.pm manually."
    fi
}

# Run main function
main "$@"
