#!/bin/bash
# committer-subject-length.sh — PreToolUse Bash hook scoped to committer.
#
# Blocks git commit commands where the subject line exceeds 50 bytes.

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
parse_input

debug_log committer-subject-length "tool=$TOOL_NAME agent=$AGENT_TYPE"

# Only gate the committer
if [ "$AGENT_TYPE" != "committer" ]; then
    exit 0
fi

if [ "$TOOL_NAME" != "Bash" ]; then
    exit 0
fi

# Only inspect git commit commands
if ! printf '%s' "$COMMAND" | grep -qE '\bgit[[:space:]]+commit\b'; then
    exit 0
fi

# Detect heredoc form: git commit -m "$(cat <<'EOF' ... EOF)" — deny; can't extract subject.
if printf '%s' "$COMMAND" | grep -qE 'git[[:space:]]+commit[[:space:]]+-m[[:space:]]+"[^"]*\$\(cat[[:space:]]+<<'; then
    deny "BLOCKED by committer-subject-length: heredoc form not supported — use -m \"subject\" with ≤50B subject line"
    exit 0
fi

# Extract commit message from -m flag (single or double quoted)
msg=$(printf '%s' "$COMMAND" | grep -oE -- '-m[[:space:]]+("([^"]+)"|'"'"'([^'"'"']+)'"'"')' | head -1 | sed -E 's/-m[[:space:]]+["'"'"']//; s/["'"'"']$//')

if [ -z "$msg" ]; then
    # No -m flag found or no message to check
    exit 0
fi

byte_count=$(printf '%s' "$msg" | wc -c | tr -d ' ')

if [ "$byte_count" -gt 50 ]; then
    deny "BLOCKED by committer-subject-length: commit subject \"$msg\" is $byte_count bytes; max 50. Shorten and retry."
    exit 0
fi

exit 0
