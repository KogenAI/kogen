#!/bin/bash
# no-python-json.sh — PreToolUse hook: deny inline python JSON parsing.
#
# HOOK-MANIFEST:
# event: PreToolUse
# matcher: Bash
# surface: user_global
# signal: none
# role: *
# harnesses: all
#
# GENERATED FROM shared/enforcement/registry.yaml — DO NOT EDIT
# Edit registry.yaml and run `make install` to regenerate.

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
parse_input

debug_log no-python-json "tool=$TOOL_NAME agent=$AGENT_TYPE cmd=$COMMAND"

# Only guard Bash tool.
if [ "$TOOL_NAME" != "Bash" ]; then
    exit 0
fi

# Deny: all patterns must match (AND logic).
if printf '%s' "$COMMAND" | grep -qE '\bpython3?\b[^|;&]*-c\b' &&
    printf '%s' "$COMMAND" | grep -qE 'import[[:space:]]+json|json\.load'; then
    deny "Don't parse JSON with python3 -c. Use Read tool — JSON files render readably. Inline python parsing is a thrash anti-pattern (see token-budget rule)."
    exit 0
fi

exit 0
