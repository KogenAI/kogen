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
# Blocks: python -c "...import json..." / python3 -c "...json.load..."
#
# Allows: python3 script.py, python3 -c "print(1)", any python invocation
#         that doesn't combine -c with import json / json.load.
#
# Rationale: parsing JSON with python3 -c is a thrash anti-pattern.
# JSON files render readably via the Read tool.

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
parse_input

debug_log no-python-json "tool=$TOOL_NAME agent=$AGENT_TYPE cmd=$COMMAND"

# Only guard Bash tool.
if [ "$TOOL_NAME" != "Bash" ]; then
    exit 0
fi

# Deny: python|python3 ... -c ... (import json OR json.load)
# Match `python` or `python3` followed (anywhere) by `-c` and code containing
# `import json` or `json.load`.
if printf '%s' "$COMMAND" | grep -qE '\bpython3?\b[^|;&]*-c\b' &&
    printf '%s' "$COMMAND" | grep -qE 'import[[:space:]]+json|json\.load'; then
    deny "Don't parse JSON with python3 -c. Use Read tool — JSON files render readably. Inline python parsing is a thrash anti-pattern (see token-budget rule)."
    exit 0
fi

exit 0
