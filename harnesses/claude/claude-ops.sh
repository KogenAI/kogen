#!/usr/bin/env bash
# See context/claude-code-cli.md for:
#   - what --tools actually controls (built-in tools, NOT subagents)
#   - how the Agent tool is gated to only project subagents
#   - which built-in subagents are denied (Plan, general-purpose, statusline-setup
#     always; Explore allowed only under CLAUDE_ROLE=debug/shape/refactor)
set -euo pipefail

server="${1:?Usage: claude-ops <server>}"

export CLAUDE_ROLE=ops

CODEGEN_DIR="${OCG_CODEGEN_DIR:-$HOME/Areas/Optimum/codegen}"
export CODEGEN_DIR

source "$CODEGEN_DIR/harnesses/claude/load-role.sh"
load_role ops

# Resolve server via ssh -G:
#   1. Try <project>-<server> (project = git toplevel basename or cwd basename)
#   2. Detect miss by checking if the Host line exists in ~/.ssh/config
#   3. On miss, prompt user for the full alias name from their config
#   NOTE: bare <arg> fallback removed — it causes multi-project alias collisions.
project_name=$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")
candidate="${project_name}-${server}"

# Check if an exact Host entry exists in ~/.ssh/config
host_defined() {
    grep -q "^Host $1$" ~/.ssh/config 2>/dev/null
}

# Append a new Host block to ~/.ssh/config for the given candidate/resolved pair.
# Returns 0 on success, 1 if block already exists (conflict) or write fails.
save_ssh_alias() {
    local candidate="$1"
    local resolved="$2"

    # Defensive: re-check if already exists (guards TOCTOU)
    if host_defined "$candidate"; then
        echo "WARN: Host $candidate already in ~/.ssh/config with different HostName; using typed value for this run." >&2
        return 1
    fi

    # Ensure ~/.ssh dir exists with proper mode
    mkdir -p ~/.ssh
    chmod 700 ~/.ssh

    # Build the block
    local timestamp
    timestamp=$(date +"%Y-%m-%d")
    local block
    block=$(printf "\n# ops-generated: %s (claude-ops %s)\nHost %s\n    HostName %s\n" "$candidate" "$timestamp" "$candidate" "$resolved")

    # Append atomically
    printf "%s" "$block" >>~/.ssh/config 2>/dev/null || {
        echo "ERROR: could not write to ~/.ssh/config" >&2
        return 1
    }

    # Ensure file mode
    chmod 600 ~/.ssh/config

    echo "Saved ssh alias to ~/.ssh/config: Host $candidate -> $resolved"
    return 0
}

if host_defined "$candidate"; then
    server_resolved=$(ssh -G "$candidate" 2>/dev/null | awk '/^hostname /{print $2}' || echo)
else
    # Miss — prompt for alias/hostname
    read -rp "No ssh alias '$candidate' found. Enter the full alias or IP from ~/.ssh/config: " user_alias

    if [[ -z "$user_alias" ]]; then
        echo "ERROR: could not resolve server alias for '$server'" >&2
        exit 1
    fi

    # Resolve via ssh -G
    server_resolved=$(ssh -G "$user_alias" 2>/dev/null | awk '/^hostname /{print $2}' || echo)

    if [[ -z "$server_resolved" ]]; then
        echo "ERROR: could not resolve ssh alias '$user_alias'" >&2
        exit 1
    fi

    # Decision: save or use-only
    if [[ "$server_resolved" == "$user_alias" ]]; then
        # Echo detected — new IP/hostname, not in config
        save_ssh_alias "$candidate" "$server_resolved" || true
    else
        # Existing alias (resolved != input)
        echo "Using existing ssh alias '$user_alias' ($server_resolved); not saving a duplicate."
    fi
fi

# Guard: if still empty, error
[[ -n "$server_resolved" ]] || {
    echo "ERROR: could not resolve server alias for '$server'" >&2
    exit 1
}

# Derive ENV_LABEL from arg name (conservative — unknown treated as PROD)
case "${server}" in
prod | production) ENV_LABEL="PROD" ;;
stage | staging) ENV_LABEL="STAGE" ;;
*) ENV_LABEL="UNKNOWN (treated as PROD)" ;;
esac

# Export OPS_SERVER and OPS_ENV so the model can verify identity self-check
export OPS_SERVER="${server_resolved}"
export OPS_ENV="${ENV_LABEL}"

OPS_CONTEXT="Server: ${server_resolved} (resolved from '${server}'), Environment: ${ENV_LABEL}"

TOOL_FLAGS=()
if [ -n "$ROLE_TOOLS" ]; then
    TOOL_FLAGS+=(--tools "$ROLE_TOOLS")
elif [ -n "$ROLE_DISALLOWED" ]; then
    TOOL_FLAGS+=(--disallowed-tools "$ROLE_DISALLOWED")
fi

OPS_STARTUP_MSG=$'## OPS STARTUP CONTEXT\n'"${OPS_CONTEXT}"$'\n\nConfirm before proceeding.'

CONTEXT_FLAGS=(
    --append-system-prompt "${OPS_STARTUP_MSG}"
)

exec claude \
    --model "$ROLE_MODEL" \
    --effort "$ROLE_EFFORT" \
    --dangerously-skip-permissions \
    "${TOOL_FLAGS[@]+"${TOOL_FLAGS[@]}"}" \
    --system-prompt "$ROLE_SYSTEM_PROMPT" \
    "${CONTEXT_FLAGS[@]}"
