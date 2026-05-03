#!/bin/bash
# Model mapping system for AI agents

# Map simple model names to provider-specific identifiers
map_model() {
    local model="$1"
    local assistant="$2"
    local provider="${3:-anthropic}" # Default to Anthropic

    # For Claude Code, just return the simple name
    if [ "$assistant" = "claude" ]; then
        echo "$model"
        return
    fi

    # For Cursor CLI, map to cursor-agent model names
    if [ "$assistant" = "cursor" ]; then
        case "$model" in
        haiku) echo "haiku-4.5" ;;
        sonnet) echo "sonnet-4.5" ;;
        opus) echo "opus-4.1" ;;
        *) echo "sonnet-4.5" ;; # Default to sonnet
        esac
        return
    fi

    # For Codex, map to OpenAI model names
    if [ "$assistant" = "codex" ]; then
        case "$model" in
        haiku) echo "gpt-5.3-codex-spark" ;;
        sonnet) echo "gpt-5.3-codex" ;;
        opus) echo "gpt-5.5" ;;
        *) echo "gpt-5.3-codex" ;; # Default to codex
        esac
        return
    fi

    # Fallback: pass through as-is
    echo "$model"
}

# Get provider from config or environment (retained for backward compatibility)
get_provider() {
    echo "anthropic"
}
