#!/bin/bash
# orchestrator-no-source-edit.sh — PreToolUse Edit|Write|MultiEdit|NotebookEdit hook.
#
# Blocks the orchestrator from editing source files directly.
# Subagents (non-empty agent_id) are allowed under no CLAUDE_ROLE (standard
# orchestrator). Under any operator role (debug, design) the write surface is
# narrowed for BOTH the orchestrator AND Agent-spawned helpers.

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
parse_input

debug_log orchestrator-no-source-edit "tool=$TOOL_NAME agent_id=$AGENT_ID role=${CLAUDE_ROLE:-}"

# Normalise to a relative path: if the path is absolute and starts with cwd,
# strip the cwd prefix so the relative-path allowlist patterns match correctly.
cwd="$CWD"
if [ -z "$cwd" ]; then
    cwd="${CLAUDE_PROJECT_DIR:-$PWD}"
fi
rel_path="$FILE_PATH"
cwd_prefix="${cwd%/}/"
case "$FILE_PATH" in
"${cwd_prefix}"*) rel_path="${FILE_PATH#"$cwd_prefix"}" ;;
esac

# Debug/design operators (read-only investigation + design-doc authoring).
# Writes scoped to codegen/designs/{drafts,ready}/ — applies to subagents too,
# so Agent-spawned helpers can't slip writes past the role's boundary.
if [ "${CLAUDE_ROLE:-}" = "debug" ] || [ "${CLAUDE_ROLE:-}" = "design" ]; then
    if [ -z "$FILE_PATH" ]; then
        exit 0
    fi
    if printf '%s' "$rel_path" | grep -qE '^codegen/designs/'; then
        exit 0
    fi
    deny "BLOCKED by orchestrator-no-source-edit: ${CLAUDE_ROLE} mode may only write to codegen/designs/ — got $FILE_PATH"
    exit 0
fi

# Subagents under no CLAUDE_ROLE (standard orchestrator spawns) — pass through.
# Their bypass applies here because they have no inherited role restriction.
if [ -n "$AGENT_ID" ]; then
    exit 0
fi

# Plain orchestrator (no CLAUDE_ROLE): writes allowed only under codegen/logging/
# and absolute /tmp/.
if [ -z "$FILE_PATH" ]; then
    exit 0
fi
if printf '%s' "$rel_path" | grep -qE '^codegen/logging/'; then
    exit 0
fi
if printf '%s' "$FILE_PATH" | grep -qE '^(/private)?/tmp/'; then
    exit 0
fi
if printf '%s' "$rel_path" | grep -qE '^codegen/designs/'; then
    exit 0
fi

deny "BLOCKED by orchestrator-no-source-edit: ${CLAUDE_ROLE:-orchestrator} may only write to codegen/logging/, codegen/designs/, or absolute /tmp/ ($FILE_PATH). Delegate source edits to developer-phoenix-backend / developer-phoenix-frontend / developer-html | developer-hugo | developer-vite."
exit 0
