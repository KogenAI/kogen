#!/usr/bin/env bash
# ssh-target.sh — shared SSH target resolution helper.
#
# Usage (source, then call):
#   source /path/to/ssh-target.sh
#   resolve_ssh_target <server> <VAR_PREFIX> [launcher_label]
#
# After a successful call:
#   ${VAR_PREFIX}_SERVER  — resolved hostname/IP (also exported)
#   ${VAR_PREFIX}_ENV     — ENV_LABEL (also exported)
#   server_resolved       — same as ${VAR_PREFIX}_SERVER
#   ENV_LABEL             — PROD / STAGE / UNKNOWN (treated as PROD)
#
# Non-interactive guard:
#   Set SSH_TARGET_NON_INTERACTIVE=1 before calling to suppress read prompts
#   and exit 1 on alias miss instead of prompting.
#
# Requires: ssh, awk, grep; ~/.ssh/config for alias resolution.

# Check if an exact Host entry exists in ~/.ssh/config
host_defined() {
    grep -q "^Host $1$" ~/.ssh/config 2>/dev/null
}

# Append a new Host block to ~/.ssh/config for the given candidate/resolved pair.
# Returns 0 on success, 1 if block already exists (conflict) or write fails.
save_ssh_alias() {
    local candidate="$1"
    local resolved="$2"
    local launcher_label="${3:-ssh-target}"

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
    block=$(printf "\n# ops-generated: %s (%s %s)\nHost %s\n    HostName %s\n" \
        "$candidate" "$launcher_label" "$timestamp" "$candidate" "$resolved")

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

# resolve_ssh_target <server> <VAR_PREFIX> [launcher_label]
#
# Resolves the SSH target for <server> using:
#   1. Try <project>-<server> candidate in ~/.ssh/config
#   2. On miss: if SSH_TARGET_NON_INTERACTIVE is set, exit 1; else prompt user
#
# Sets and exports:
#   server_resolved          — resolved hostname/IP
#   ENV_LABEL                — PROD / STAGE / UNKNOWN (treated as PROD)
#   ${VAR_PREFIX}_SERVER     — same as server_resolved
#   ${VAR_PREFIX}_ENV        — same as ENV_LABEL
resolve_ssh_target() {
    local server="$1"
    local prefix="$2"
    local launcher_label="${3:-ssh-target}"

    local project_name
    project_name=$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")
    local candidate="${project_name}-${server}"

    if host_defined "$candidate"; then
        server_resolved=$(ssh -G "$candidate" 2>/dev/null | awk '/^hostname /{print $2}' || echo)
    else
        # Miss in non-interactive context — exit immediately
        if [[ -n "${SSH_TARGET_NON_INTERACTIVE:-}" ]]; then
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
            save_ssh_alias "$candidate" "$server_resolved" "$launcher_label" || true
        else
            # Existing alias (resolved != input)
            echo "Using existing ssh alias '$user_alias' ($server_resolved); not saving a duplicate."
        fi
    fi

    # Guard: if still empty, error
    [[ -n "${server_resolved:-}" ]] || {
        echo "ERROR: could not resolve server alias for '$server'" >&2
        exit 1
    }

    # Derive ENV_LABEL from arg name (conservative — unknown treated as PROD)
    case "${server}" in
    prod | production) ENV_LABEL="PROD" ;;
    stage | staging) ENV_LABEL="STAGE" ;;
    *) ENV_LABEL="UNKNOWN (treated as PROD)" ;;
    esac

    # Export prefixed vars so the model can verify identity self-check
    export "${prefix}_SERVER=${server_resolved}"
    export "${prefix}_ENV=${ENV_LABEL}"
}
