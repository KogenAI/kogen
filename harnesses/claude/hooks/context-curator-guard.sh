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
# registration only (hand-authored body) — the registry entry for this hook
# is `kind: registration`, which emits ONLY the settings.json wiring; the
# check logic below is NOT generated and is safe to hand-edit.
#
# Restricts Edit/Write/MultiEdit to the curator's allowed write surface:
#   - project context/**: context/** relative to CWD
#   - rules: codegen/rules/** (symlink to shared/rules; used by all curators)
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

# Allowed: project context/** (relative or absolute, any project root)
if printf '%s' "$FILE_PATH" | grep -qE '(^|/)context/'; then
    exit 0
fi

# Allowed: codegen/rules/** (symlink to shared/rules)
if printf '%s' "$FILE_PATH" | grep -qE '(^|/)codegen/rules(/|$)'; then
    exit 0
fi

# Allowed: codegen/logging/** (session logs)
if printf '%s' "$FILE_PATH" | grep -qE '(^|/)codegen/logging/'; then
    exit 0
fi

# Allowed: PROJECT_CONTEXT.md § Domain Context Files rows (curator maintains index↔context parity)
if printf '%s' "$FILE_PATH" | grep -qE '(^|/)PROJECT_CONTEXT\.md$'; then
    exit 0
fi

# Everything else is denied for context-curator.
deny "BLOCKED by context-curator-guard: $FILE_PATH is outside the curator's allowed write surface. Curator may only write to: context/**, codegen/rules/**, codegen/logging/**, PROJECT_CONTEXT.md."
exit 0
