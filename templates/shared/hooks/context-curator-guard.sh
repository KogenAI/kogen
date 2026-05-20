#!/bin/bash
# context-curator-guard.sh — PreToolUse hook for context-curator.
#
# HOOK-MANIFEST:
# event: PreToolUse
# matcher: Edit|Write|MultiEdit
# surface: user_global
# signal: AGENT_TYPE
# role: context-curator
# harnesses: all
#
# Restricts Edit/Write/MultiEdit to the curator's allowed write surface:
#   - combobulate context/**: context/** relative to CWD
#   - OCG context/rules/**: /Users/almirsarajcic/Areas/Optimum/context/rules/**
#   - session logs: codegen/logging/** relative to CWD
#
# All other agents pass through unconditionally.

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
parse_input

debug_log context-curator-guard "tool=$TOOL_NAME agent=$AGENT_TYPE file=$FILE_PATH"

# Only gate the context-curator; all other agents pass through.
case "$AGENT_TYPE" in
context-curator) ;;
*)
    exit 0
    ;;
esac

case "$TOOL_NAME" in
Edit | Write | MultiEdit) ;;
*)
    exit 0
    ;;
esac

if [ -z "$FILE_PATH" ]; then
    exit 0
fi

# Allowed: combobulate context/** (relative or absolute under CWD)
if printf '%s' "$FILE_PATH" | grep -qE '(^|/)context/'; then
    # Further: only the context-curator's allowed subtrees
    # Allow context/** under any project root (combobulate) OR OCG context/rules/
    # Check for OCG context/rules path
    if printf '%s' "$FILE_PATH" | grep -qE '^/Users/almirsarajcic/Areas/Optimum/context/rules(/|$)'; then
        exit 0
    fi
    # Allow any context/** path (project-local)
    if printf '%s' "$FILE_PATH" | grep -qE '(^|/)context/'; then
        exit 0
    fi
fi

# Allowed: codegen/logging/** (session logs)
if printf '%s' "$FILE_PATH" | grep -qE '(^|/)codegen/logging/'; then
    exit 0
fi

# Everything else is denied for context-curator.
deny "BLOCKED by context-curator-guard: $FILE_PATH is outside the curator's allowed write surface. Curator may only write to: context/**, /Users/almirsarajcic/Areas/Optimum/context/rules/**, codegen/logging/**."
exit 0
