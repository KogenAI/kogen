#!/bin/bash

# AI Agent Configuration Management

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$HOME/.ocg/config.json"
CONFIG_DIR="$(dirname "$CONFIG_FILE")"

# Ensure config directory exists
mkdir -p "$CONFIG_DIR"

# Initialize config if it doesn't exist
init_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        cat >"$CONFIG_FILE" <<EOF
{
    "default_agent": "claude",
    "agents": {
        "claude": {
            "enabled": true
        },
        "opencode": {
            "enabled": true,
            "provider": "anthropic"
        },
        "cursor": {
            "enabled": true
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
    echo "🤖 AI Agent Configuration"
    echo "========================="
    echo ""
    echo "Default Agent: $(get_config "default_agent")"
    echo ""
    echo "Claude Code:"
    echo "  Enabled: $(get_config "agents.claude.enabled")"
    if command -v claude >/dev/null 2>&1; then
        echo "  Installed: ✅"
    else
        echo "  Installed: ❌"
    fi

    echo ""
    echo "OpenCode:"
    echo "  Enabled: $(get_config "agents.opencode.enabled")"
    echo "  Provider: $(get_config "agents.opencode.provider")"
    if command -v opencode >/dev/null 2>&1; then
        echo "  Installed: ✅"
    else
        echo "  Installed: ❌"
    fi

    echo ""
    echo "Cursor CLI:"
    echo "  Enabled: $(get_config "agents.cursor.enabled")"
    if command -v cursor-agent >/dev/null 2>&1; then
        echo "  Installed: ✅"
        cursor-agent --version 2>/dev/null || echo "  Version: unknown"
    else
        echo "  Installed: ❌"
    fi

    echo ""
    echo "Model Mappings:"
    # Model mappings are handled by model-mapper.sh, not stored in config
    source "$SCRIPT_DIR/ai-agents/model-mapper.sh"
    echo "  sonnet → $(map_model "sonnet" "opencode" "anthropic")"
    echo "  opus → $(map_model "opus" "opencode" "anthropic")"
}

# Main command handling
case "$1" in
set)
    if [ "$2" = "default" ]; then
        if [ -z "$3" ]; then
            echo "Usage: ocg ai-config set default [claude|opencode|cursor]"
            exit 1
        fi
        if [ "$3" != "claude" ] && [ "$3" != "opencode" ] && [ "$3" != "cursor" ]; then
            echo "❌ Invalid agent: $3"
            echo "   Valid options: claude, opencode, cursor"
            exit 1
        fi
        set_config "default_agent" "$3"
        echo "✅ Default AI agent set to: $3"
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
        result=$(get_config "default_agent")
        if [ -n "$result" ]; then
            echo "$result"
        else
            echo "❌ No default agent configured"
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
    echo "  set default <agent>      Set default AI agent (claude|opencode|cursor)"
    echo "  get default              Show current default agent"
    echo "  get <key>                Get a configuration value"
    echo "  set <key> <value>        Set a configuration value"
    echo "  status                   Show full configuration"
    exit 1
    ;;
esac
