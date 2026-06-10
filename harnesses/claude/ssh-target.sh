#!/usr/bin/env bash
# ssh-target.sh — shared SSH target resolution helper.
#
# Usage (source, then call):
#   source /path/to/ssh-target.sh
#   resolve_ssh_target <server> <VAR_PREFIX> [launcher_label]
#
# After a successful call:
#   ${VAR_PREFIX}_SERVER       — resolved hostname/IP (also exported)
#   ${VAR_PREFIX}_ENV          — ENV_LABEL (also exported)
#   ${VAR_PREFIX}_LOGIN_USER   — ssh login user (also exported)
#   ${VAR_PREFIX}_OPERATE_AS   — operate-as user (also exported; may be empty)
#   server_resolved            — same as ${VAR_PREFIX}_SERVER
#   ENV_LABEL                  — PROD / STAGE / UNKNOWN (treated as PROD)
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
# Optional params: login_user (arg 4), operate_as (arg 5)
save_ssh_alias() {
    local candidate="$1"
    local resolved="$2"
    local launcher_label="${3:-ssh-target}"
    local login_user="${4:-}"
    local operate_as="${5:-}"

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

    # Append atomically — use separate printf calls so newlines are unambiguous
    {
        printf "\n# ops-generated: %s (%s %s)\nHost %s\n    HostName %s\n" \
            "$candidate" "$launcher_label" "$timestamp" "$candidate" "$resolved"
        if [[ -n "$login_user" ]]; then
            printf "    User %s\n" "$login_user"
        fi
        if [[ -n "$operate_as" ]]; then
            printf "    # ops-operate-as: %s\n" "$operate_as"
        fi
    } >>~/.ssh/config 2>/dev/null || {
        echo "ERROR: could not write to ~/.ssh/config" >&2
        return 1
    }

    # Ensure file mode
    chmod 600 ~/.ssh/config

    echo "Saved ssh alias to ~/.ssh/config: Host $candidate -> $resolved"
    return 0
}

# block_has_user <candidate> <config_file>
# Returns 0 if the Host block for <candidate> has a User line, 1 otherwise.
block_has_user() {
    local candidate="$1"
    local config_file="$2"
    awk -v host="Host $candidate" '
        $0 == host { in_block=1; next }
        in_block && /^Host / { exit }
        in_block && /^[[:space:]]+User / { found=1; exit }
        END { exit !found }
    ' "$config_file"
}

# prompt_user_identity
# Prompts for login user (default: root) and operate-as user (optional).
# Skipped entirely under SSH_TARGET_NON_INTERACTIVE=1 (returns empty).
# Outputs: login_user on first line, operate_as on second line.
prompt_user_identity() {
    local login_user operate_as
    if [[ -n "${SSH_TARGET_NON_INTERACTIVE:-}" ]]; then
        printf '%s\n%s' "" ""
        return
    fi
    read -rp "Login user [root]: " login_user || true
    login_user="${login_user:-root}"
    read -rp "Operate-as user (su to after login, Enter to skip): " operate_as || true
    printf '%s\n%s' "$login_user" "$operate_as"
}

# backfill_ssh_user <candidate> <config_file>
# For an existing alias that has HostName but no User line:
# Prompts for login user + operate-as, then rewrites the block to add them.
# Idempotent: skips if User already present. Interactive only (skipped under
# SSH_TARGET_NON_INTERACTIVE).
backfill_ssh_user() {
    local candidate="$1"
    local config_file="$2"

    # Idempotency: skip if User already present
    if block_has_user "$candidate" "$config_file"; then
        return 0
    fi

    # Interactive only
    if [[ -n "${SSH_TARGET_NON_INTERACTIVE:-}" ]]; then
        return 0
    fi

    # Gather identity
    local identity
    identity=$(prompt_user_identity)
    local login_user operate_as
    login_user=$(printf '%s' "$identity" | head -1)
    operate_as=$(printf '%s' "$identity" | tail -1)

    login_user="${login_user:-root}"

    # Rewrite via temp file (BSD/GNU sed-portable)
    local tmpfile
    tmpfile=$(mktemp)
    trap 'rm -f "$tmpfile"' EXIT

    awk -v host="Host $candidate" \
        -v login_user="$login_user" \
        -v operate_as="$operate_as" '
        $0 == host { in_block=1; print; next }
        in_block && /^Host / { in_block=0 }
        in_block && /^[[:space:]]+HostName / {
            print
            print "    User " login_user
            if (operate_as != "") {
                print "    # ops-operate-as: " operate_as
            }
            next
        }
        { print }
    ' "$config_file" >"$tmpfile"

    mv "$tmpfile" "$config_file"
    chmod 600 "$config_file"

    trap - EXIT
}

# resolve_ssh_target <server> <VAR_PREFIX> [launcher_label]
#
# Resolves the SSH target for <server> using:
#   1. Try <project>-<server> candidate in ~/.ssh/config
#   2. On miss: if SSH_TARGET_NON_INTERACTIVE is set, exit 1; else prompt user
#
# Sets and exports:
#   server_resolved              — resolved hostname/IP
#   ENV_LABEL                    — PROD / STAGE / UNKNOWN (treated as PROD)
#   ${VAR_PREFIX}_SERVER         — same as server_resolved
#   ${VAR_PREFIX}_ENV            — same as ENV_LABEL
#   ${VAR_PREFIX}_LOGIN_USER     — ssh login user
#   ${VAR_PREFIX}_OPERATE_AS     — operate-as user (may be empty)
resolve_ssh_target() {
    local server="$1"
    local prefix="$2"
    local launcher_label="${3:-ssh-target}"

    local project_name
    project_name=$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")
    local candidate="${project_name}-${server}"

    local login_user="" operate_as=""

    if host_defined "$candidate"; then
        server_resolved=$(ssh -G "$candidate" 2>/dev/null | awk '/^hostname /{print $2}' || echo)

        # Backfill User if absent (interactive only)
        backfill_ssh_user "$candidate" ~/.ssh/config

        # Parse login_user from block
        login_user=$(awk -v host="Host $candidate" '
            $0 == host { in_block=1; next }
            in_block && /^Host / { exit }
            in_block && /^[[:space:]]+User / { sub(/^[[:space:]]+User[[:space:]]+/, ""); print; exit }
        ' ~/.ssh/config || true)

        # Parse operate_as from block
        operate_as=$(awk -v host="Host $candidate" '
            $0 == host { in_block=1; next }
            in_block && /^Host / { exit }
            in_block && /^[[:space:]]+# ops-operate-as:/ {
                sub(/^[[:space:]]+# ops-operate-as:[[:space:]]*/, ""); print; exit
            }
        ' ~/.ssh/config || true)
    else
        # Miss in non-interactive context — exit immediately
        if [[ -n "${SSH_TARGET_NON_INTERACTIVE:-}" ]]; then
            echo "ERROR: ssh alias '$candidate' not found in ~/.ssh/config" >&2
            exit 1
        fi

        # Miss in interactive mode — prompt for alias/hostname
        read -rp "No ssh alias '$candidate' found. Enter the full alias or IP from ~/.ssh/config: " user_alias || true

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
            # Gather user identity before saving
            local identity
            identity=$(prompt_user_identity)
            login_user=$(printf '%s' "$identity" | head -1)
            operate_as=$(printf '%s' "$identity" | tail -1)
            login_user="${login_user:-root}"

            save_ssh_alias "$candidate" "$server_resolved" "$launcher_label" "$login_user" "$operate_as" || true
        else
            # Existing alias (resolved != input)
            echo "Using existing ssh alias '$user_alias' ($server_resolved); not saving a duplicate."

            # Parse identity from the existing alias if present
            login_user=$(awk -v host="Host $user_alias" '
                $0 == host { in_block=1; next }
                in_block && /^Host / { exit }
                in_block && /^[[:space:]]+User / { sub(/^[[:space:]]+User[[:space:]]+/, ""); print; exit }
            ' ~/.ssh/config || true)
            operate_as=$(awk -v host="Host $user_alias" '
                $0 == host { in_block=1; next }
                in_block && /^Host / { exit }
                in_block && /^[[:space:]]+# ops-operate-as:/ {
                    sub(/^[[:space:]]+# ops-operate-as:[[:space:]]*/, ""); print; exit
                }
            ' ~/.ssh/config || true)
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
    export "${prefix}_LOGIN_USER=${login_user}"
    export "${prefix}_OPERATE_AS=${operate_as}"
}
