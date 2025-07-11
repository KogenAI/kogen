#!/bin/bash
# Universal AI assistant wrapper

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the model mapper
source "$SCRIPT_DIR/model-mapper.sh"

# Load configuration
load_config() {
    local config_file="$HOME/.ocg/config.json"
    if [ -f "$config_file" ]; then
        DEFAULT_ASSISTANT=$(jq -r '.default_assistant // empty' "$config_file" 2>/dev/null)
    fi
}

# Detect which assistant to use
detect_assistant() {
    # Check environment variable first
    if [ -n "$AI_ASSISTANT" ]; then
        echo "$AI_ASSISTANT"
        return
    fi

    # Load default from config
    load_config
    if [ -n "$DEFAULT_ASSISTANT" ]; then
        echo "$DEFAULT_ASSISTANT"
        return
    fi

    echo "none"
}

# Run the selected assistant
run_assistant() {
    local assistant="$1"
    local model="$2"
    local base_dir="$3" # Pass workspace directory

    # Both assistants use the same PROMPT.md file
    local prompt_file="$base_dir/codegen/PROMPT.md"
    if [ ! -f "$prompt_file" ]; then
        echo "❌ Prompt file not found: $prompt_file"
        exit 1
    fi

    case "$assistant" in
    claude)
        # Set Claude-specific environment variables
        export CLAUDE_BASH_MAINTAIN_PROJECT_WORKING_DIR=true

        echo "🤖 Using Claude Code with model: $model"
        claude --dangerously-skip-permissions --model "$model" <"$prompt_file"
        ;;
    opencode)
        # Get provider and map model name
        local provider=$(get_provider "opencode")
        local oc_model=$(map_model "$model" "opencode" "$provider")

        echo "🤖 Using OpenCode with $provider provider and model: $oc_model"

        # Read the prompt file content
        local prompt_content=$(<"$prompt_file")

        # Launch OpenCode in interactive TUI mode with initial prompt
        # This allows continuing the conversation after the initial response
        cd "$base_dir"
        opencode --model "$provider/$oc_model" --prompt "$prompt_content"
        ;;
    *)
        echo "❌ Unknown AI assistant: $assistant"
        echo "   Valid options: claude, opencode"
        exit 1
        ;;
    esac
}

# Main execution
if [ $# -lt 3 ]; then
    echo "Usage: $0 <assistant> <model> <workspace_dir>"
    exit 1
fi

run_assistant "$1" "$2" "$3"
