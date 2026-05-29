#!/usr/bin/env bash
# Pi ops launcher — analogous to claude-ops.sh.
#
# PI_ROLE=ops is exported before exec.
# Tool surface: read,grep,find,ls,edit,write,bash — agent instructed via system
# prompt to operate with care on production/staging servers.
# Server resolved via ssh -G; ENV_LABEL derived from arg name.
# OPS_CONTEXT appended to system prompt before exec.
set -euo pipefail

server="${1:?Usage: pi-ops <server>}"

if ! command -v pi >/dev/null 2>&1; then
    echo "ERROR: 'pi' binary not found in PATH." >&2
    echo "Install: npm install -g @earendil-works/pi-coding-agent" >&2
    echo "See README.md § Prerequisites for details." >&2
    exit 127
fi

export PI_ROLE=ops

CODEGEN_DIR="${OCG_CODEGEN_DIR:-$HOME/Areas/Optimum/codegen}"
export CODEGEN_DIR

SYSTEM_PROMPT_FILE="$CODEGEN_DIR/harnesses/pi/pi-ops-system-prompt.txt"
if [ ! -f "$SYSTEM_PROMPT_FILE" ]; then
    echo "ERROR: pi-ops-system-prompt.txt not found at $SYSTEM_PROMPT_FILE" >&2
    exit 1
fi
ROLE_SYSTEM_PROMPT=$(cat "$SYSTEM_PROMPT_FILE")

cfg="${CODEGEN_DIR}/templates/generator/config.yaml"
ROLE_MODEL=$(yq -r ".harness.ops.pi.model" "$cfg")
ROLE_EFFORT=$(yq -r ".harness.ops.pi.effort" "$cfg")

# Resolve server via ssh -G:
#   1. Try <project>-<server> (project = git toplevel basename or cwd basename)
#   2. Detect miss by checking if the Host line exists in ~/.ssh/config
#   3. On miss in non-interactive mode (PI_NON_INTERACTIVE), exit 1
#   4. On miss in interactive mode, prompt user for the full alias name
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
    block=$(printf "\n# ops-generated: %s (pi-ops %s)\nHost %s\n    HostName %s\n" "$candidate" "$timestamp" "$candidate" "$resolved")

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
    # Miss in non-interactive context — exit immediately
    if [[ -n "${PI_NON_INTERACTIVE:-}" ]]; then
        echo "ERROR: ssh alias '$candidate' not found in ~/.ssh/config" >&2
        exit 1
    fi

    # Miss in interactive mode — prompt for alias/hostname
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

# Append OPS_CONTEXT to system prompt (mirrors pi-shape.sh PROJECT_CONTEXT pattern)
ROLE_SYSTEM_PROMPT="${ROLE_SYSTEM_PROMPT}

## OPS STARTUP CONTEXT
${OPS_CONTEXT}

Confirm before proceeding."

EXTENSIONS_DIR="$CODEGEN_DIR/harnesses/pi/pi-extensions"

NON_INTERACTIVE_FLAGS=()
if [[ -n "${PI_NON_INTERACTIVE:-}" ]]; then
    NON_INTERACTIVE_FLAGS+=(-p --mode text --no-session)
fi

exec pi \
    "${NON_INTERACTIVE_FLAGS[@]+"${NON_INTERACTIVE_FLAGS[@]}"}" \
    --provider openai-codex \
    --model "$ROLE_MODEL" \
    --thinking "$ROLE_EFFORT" \
    --tools read,grep,find,ls,edit,write,bash \
    --no-extensions \
    --extension "$EXTENSIONS_DIR/askuserquestion" \
    --extension "$EXTENSIONS_DIR/subagents" \
    --extension "$EXTENSIONS_DIR/web-utils" \
    --system-prompt "$ROLE_SYSTEM_PROMPT"
