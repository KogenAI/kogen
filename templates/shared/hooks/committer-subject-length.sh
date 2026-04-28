#!/bin/bash
# committer-subject-length.sh — PreToolUse Bash hook scoped to committer.
#
# Blocks git commit commands where the subject line exceeds 50 bytes.
#
# Exit codes:
#   0 — allow the tool call
#   2 — block (Claude Code PreToolUse convention; stderr fed back to model)

set -euo pipefail

input=$(cat)

tool_name=$(printf '%s' "$input" | jq -r '.tool_name // ""')
agent_type=$(printf '%s' "$input" | jq -r '.agent_type // ""')

# Debug logging
if [ -n "${COMBOBULATE_HOOKS_DEBUG:-}" ] || [ -n "${COMBOBULATE_CSL_DEBUG:-}" ]; then
    printf '%s tool=%s agent_type=%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        "$tool_name" "$agent_type" \
        >>/tmp/committer-subject-length-debug.log 2>/dev/null || true
fi

# Only gate the committer
if [ "$agent_type" != "committer" ]; then
    exit 0
fi

if [ "$tool_name" != "Bash" ]; then
    exit 0
fi

command=$(printf '%s' "$input" | jq -r '.tool_input.command // ""')

# Only inspect git commit commands
if ! printf '%s' "$command" | grep -qE '\bgit[[:space:]]+commit\b'; then
    exit 0
fi

# Extract commit message from -m flag (single or double quoted)
msg=$(printf '%s' "$command" | grep -oE -- '-m[[:space:]]+("([^"]+)"|'"'"'([^'"'"']+)'"'"')' | head -1 | sed -E 's/-m[[:space:]]+["'"'"']//; s/["'"'"']$//')

if [ -z "$msg" ]; then
    # No -m flag found or no message to check
    exit 0
fi

byte_count=$(printf '%s' "$msg" | wc -c | tr -d ' ')

if [ "$byte_count" -gt 50 ]; then
    printf 'BLOCKED by committer-subject-length: commit subject "%s" is %s bytes; max 50. Shorten and retry.\n' \
        "$msg" "$byte_count" >&2
    exit 2
fi

exit 0
