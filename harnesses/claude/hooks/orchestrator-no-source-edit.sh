#!/bin/bash
# orchestrator-no-source-edit.sh — PreToolUse Edit|Write|MultiEdit|NotebookEdit hook.
#
# HOOK-MANIFEST:
# event: PreToolUse
# matcher: Write|Edit|MultiEdit|NotebookEdit
# surface: user_global
# signal: CLAUDE_ROLE_FAMILY
# role: *
# harnesses: claude_code
# rationale: CLAUDE_ROLE_FAMILY-keyed launcher mode guard, Pi has no equivalent launcher concept
#
# Blocks the orchestrator from editing source files directly.
# Subagents (non-empty agent_id) are allowed under no CLAUDE_ROLE_FAMILY (standard
# orchestrator). Under any operator role (debug, shape, refactor) the write surface
# is narrowed for BOTH the orchestrator AND Agent-spawned helpers.
#
# Responds to CLAUDE_ROLE (Claude Code) and PI_ROLE (PI harness)
# via resolve_role() — precedence: CLAUDE_ROLE > PI_ROLE.

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
source "$(dirname "$0")/_role.sh"
parse_input

role=$(resolve_role)
debug_log orchestrator-no-source-edit "tool=$TOOL_NAME agent_id=$AGENT_ID role=${role}"

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

# Debug/shape/refactor operators (read-only investigation + pitch authoring).
# Writes scoped to codegen/pitches/ — applies to subagents too,
# so Agent-spawned helpers can't slip writes past the role's boundary.
if [ "$role" = "debug" ] || [ "$role" = "shape" ] || [ "$role" = "refactor" ]; then
    if [ -z "$FILE_PATH" ]; then
        exit 0
    fi
    if printf '%s' "$rel_path" | grep -qE '^codegen/pitches/'; then
        exit 0
    fi
    deny "BLOCKED by orchestrator-no-source-edit: ${role} mode may only write to codegen/pitches/ — got $FILE_PATH"
    exit 0
fi

# Subagents under no role (standard orchestrator spawns) — pass through.
# Their bypass applies here because they have no inherited role restriction.
if [ -n "$AGENT_ID" ]; then
    exit 0
fi

# Plain orchestrator (no role): writes allowed only under codegen/logging/
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
if printf '%s' "$rel_path" | grep -qE '^codegen/pitches/'; then
    exit 0
fi

deny "BLOCKED by orchestrator-no-source-edit: ${role:-orchestrator} may only write to codegen/logging/, codegen/pitches/, or absolute /tmp/ ($FILE_PATH). Delegate source edits to developer-phoenix-backend / developer-phoenix-frontend / developer-html | developer-hugo | developer-vite."
exit 0
