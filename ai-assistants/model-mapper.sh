#!/bin/bash
# Model mapping system for AI assistants

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
        sonnet) echo "sonnet-4.5" ;;
        opus) echo "opus-4.1" ;;
        *) echo "sonnet-4.5" ;; # Default to sonnet
        esac
        return
    fi

    # For OpenCode with Anthropic provider, map to full model names
    if [ "$provider" = "anthropic" ]; then
        case "$model" in
        sonnet) echo "claude-sonnet-4-5-20250929" ;;
        opus) echo "claude-opus-4-1-20250805" ;;
        *) echo "claude-sonnet-4-5-20250929" ;; # Default to sonnet
        esac
    else
        # For other providers, pass through as-is
        echo "$model"
    fi
}

# Get provider from config or environment
get_provider() {
    local assistant="$1"
    if [ "$assistant" = "opencode" ]; then
        # Check environment variable first
        if [ -n "$OPENCODE_PROVIDER" ]; then
            echo "$OPENCODE_PROVIDER"
            return
        fi

        # Check config file
        local config_file="$HOME/.ocg/config.json"
        if [ -f "$config_file" ]; then
            local provider=$(jq -r '.assistants.opencode.provider // empty' "$config_file" 2>/dev/null)
            if [ -n "$provider" ]; then
                echo "$provider"
                return
            fi
        fi

        # Default to anthropic
        echo "anthropic"
    else
        echo "anthropic"
    fi
}
