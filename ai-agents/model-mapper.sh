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
        *)
            echo "ERROR: model-mapper: unknown cursor model shorthand '$model' (known: haiku, sonnet, opus)" >&2
            exit 64
            ;;
        esac
        return
    fi

    # For Codex, map to OpenAI model names
    if [ "$assistant" = "codex" ]; then
        case "$model" in
        haiku) echo "gpt-5.5-mini" ;;
        sonnet) echo "gpt-5.5" ;;
        opus) echo "gpt-5.5" ;;
        *)
            echo "ERROR: model-mapper: unknown codex model shorthand '$model' (known: haiku, sonnet, opus)" >&2
            exit 64
            ;;
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

# When executed directly (not sourced), dispatch to map_model so callers can
# smoke-test fail-fast paths: `bash model-mapper.sh codex bogus` -> exit 64.
# Argument order matches the smoke convention (assistant first, model second).
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    if [ "$#" -lt 2 ]; then
        echo "Usage: $0 <assistant> <model>" >&2
        exit 64
    fi
    map_model "$2" "$1"
fi
