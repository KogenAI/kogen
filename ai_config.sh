#!/bin/bash

# AI Assistant Configuration Management

CONFIG_FILE="$HOME/.ocg/config.json"
CONFIG_DIR="$(dirname "$CONFIG_FILE")"

# Ensure config directory exists
mkdir -p "$CONFIG_DIR"

# Initialize config if it doesn't exist
init_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        cat >"$CONFIG_FILE" <<EOF
{
    "default_assistant": "claude",
    "assistants": {
        "claude": {
            "enabled": true
        },
        "opencode": {
            "enabled": true,
            "provider": "anthropic"
        }
    }
}
EOF
    fi
}

# Get a config value
get_config() {
    local key="$1"
    init_config
    jq -r ".$key // empty" "$CONFIG_FILE" 2>/dev/null
}

# Set a config value
set_config() {
    local key="$1"
    local value="$2"
    init_config

    # Create a temporary file
    local tmp_file=$(mktemp)

    # Update the config
    if [[ "$key" == *.* ]]; then
        # Handle nested keys
        jq ".$key = \"$value\"" "$CONFIG_FILE" >"$tmp_file"
    else
        # Handle top-level keys
        jq ".$key = \"$value\"" "$CONFIG_FILE" >"$tmp_file"
    fi

    # Move the temp file to the config file
    mv "$tmp_file" "$CONFIG_FILE"
}

# Show full configuration
show_status() {
    init_config
    echo "🤖 AI Assistant Configuration"
    echo "============================"
    echo ""
    echo "Default Assistant: $(get_config "default_assistant")"
    echo ""
    echo "Claude Code:"
    echo "  Enabled: $(get_config "assistants.claude.enabled")"
    if command -v claude >/dev/null 2>&1; then
        echo "  Installed: ✅"
    else
        echo "  Installed: ❌"
    fi

    echo ""
    echo "OpenCode:"
    echo "  Enabled: $(get_config "assistants.opencode.enabled")"
    echo "  Provider: $(get_config "assistants.opencode.provider")"
    if command -v opencode >/dev/null 2>&1; then
        echo "  Installed: ✅"
    else
        echo "  Installed: ❌"
    fi

    echo ""
    echo "Model Mappings:"
    # Model mappings are handled by model-mapper.sh, not stored in config
    source "$SCRIPT_DIR/ai-assistants/model-mapper.sh"
    echo "  sonnet → $(map_model "sonnet" "opencode" "anthropic")"
    echo "  opus → $(map_model "opus" "opencode" "anthropic")"
}

# Main command handling
case "$1" in
set)
    if [ "$2" = "default" ]; then
        if [ -z "$3" ]; then
            echo "Usage: ocg ai-config set default [claude|opencode]"
            exit 1
        fi
        if [ "$3" != "claude" ] && [ "$3" != "opencode" ]; then
            echo "❌ Invalid assistant: $3"
            echo "   Valid options: claude, opencode"
            exit 1
        fi
        set_config "default_assistant" "$3"
        echo "✅ Default AI assistant set to: $3"
    else
        if [ -z "$2" ] || [ -z "$3" ]; then
            echo "Usage: ocg ai-config set <key> <value>"
            exit 1
        fi
        set_config "$2" "$3"
        echo "✅ Configuration updated: $2 = $3"
    fi
    ;;
get)
    if [ "$2" = "default" ]; then
        result=$(get_config "default_assistant")
        if [ -n "$result" ]; then
            echo "$result"
        else
            echo "❌ No default assistant configured"
            exit 1
        fi
    else
        if [ -z "$2" ]; then
            echo "Usage: ocg ai-config get <key>"
            exit 1
        fi
        result=$(get_config "$2")
        if [ -n "$result" ]; then
            echo "$result"
        else
            echo "❌ Configuration key not found: $2"
            exit 1
        fi
    fi
    ;;
status)
    show_status
    ;;
*)
    echo "Usage: ocg ai-config <action> [options]"
    echo "Actions:"
    echo "  set default <assistant>  Set default AI assistant (claude|opencode)"
    echo "  get default              Show current default assistant"
    echo "  get <key>                Get a configuration value"
    echo "  set <key> <value>        Set a configuration value"
    echo "  status                   Show full configuration"
    exit 1
    ;;
esac
