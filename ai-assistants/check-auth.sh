#!/bin/bash
# Check authentication for AI assistants

check_assistant_auth() {
    local assistant="$1"

    case "$assistant" in
    claude)
        if [ ! -d "$HOME/.config/claude" ] || [ ! -f "$HOME/.config/claude/config.json" ]; then
            echo "❌ Claude Code not authenticated"
            echo "   Please run 'claude login' first"
            return 1
        fi
        ;;
    opencode)
        # Check if opencode is installed
        if ! command -v opencode >/dev/null 2>&1; then
            echo "❌ OpenCode not installed"
            echo "   Please run 'make install' to install OpenCode"
            return 1
        fi

        # OpenCode has multiple ways to authenticate:
        # 1. Environment variables (ANTHROPIC_API_KEY, etc.)
        # 2. Config file with API keys
        # 3. System keychain integration
        # 4. Already authenticated in a session

        # Try to run a simple opencode command to check if it's authenticated
        if opencode status >/dev/null 2>&1; then
            # OpenCode is working, authentication is set up
            return 0
        fi

        # If status command fails, check for common auth methods
        local has_auth=false

        # Check environment variables
        if [ -n "$ANTHROPIC_API_KEY" ] || [ -n "$OPENAI_API_KEY" ] || [ -n "$GOOGLE_API_KEY" ]; then
            has_auth=true
        fi

        # Check opencode config files (multiple possible locations)
        for config_file in "$HOME/.config/opencode/config.json" "$HOME/.opencode/config.json" "$HOME/.opencode.json"; do
            if [ -f "$config_file" ]; then
                # Just check if file exists and has some content
                if [ -s "$config_file" ]; then
                    has_auth=true
                    break
                fi
            fi
        done

        if [ "$has_auth" = "false" ]; then
            echo "❌ OpenCode authentication not detected"
            echo "   Please ensure OpenCode is properly configured"
            echo "   Try running 'opencode status' to verify setup"
            return 1
        fi
        ;;
    *)
        echo "❌ Unknown AI assistant: $assistant"
        return 1
        ;;
    esac

    return 0
}
