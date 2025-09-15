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

    # For OpenCode with Anthropic provider, map to full model names
    if [ "$provider" = "anthropic" ]; then
        case "$model" in
        sonnet) echo "claude-sonnet-4-20250514" ;;       # Claude 4 Sonnet
        opus) echo "claude-opus-4-1-20250805" ;;         # Claude 4.1 Opus (latest)
        sonnet-3.7) echo "claude-3-7-sonnet-20250219" ;; # Claude 3.7 Sonnet (hybrid reasoning)
        haiku) echo "claude-3-5-haiku-20241022" ;;       # Claude 3.5 Haiku (fast/economical)
        *) echo "$model" ;;                              # Pass through unknown models
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
