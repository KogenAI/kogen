#!/bin/bash
# orchestrator-no-source-edit.sh — PreToolUse Edit|Write|MultiEdit|NotebookEdit hook.
#
# Blocks the orchestrator from editing source files directly.
# Subagents (non-empty agent_id) are always allowed.
# Orchestrator (empty agent_id) may only edit:
#   - codegen/logging/ (session logs)
#   - codegen/ (any codegen dir file)
#   - tmp/ (temp files)
#   - Top-level .md files (CLAUDE.md, README.md, AGENTS.md, etc.)

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
parse_input

debug_log orchestrator-no-source-edit "tool=$TOOL_NAME agent_id=$AGENT_ID"

# Debug mode is read-only investigation — no writes allowed.
if [ "${CLAUDE_ROLE:-}" = "debug" ]; then
    deny "BLOCKED by orchestrator-no-source-edit: debug mode is read-only investigation — Edit/Write forbidden"
    exit 0
fi

# Subagents (non-empty agent_id) — pass through
if [ -n "$AGENT_ID" ]; then
    exit 0
fi

if [ -z "$FILE_PATH" ]; then
    exit 0
fi

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

# Allowed paths for the orchestrator:
# 1. codegen/ directory (session logs, pending flags, any codegen file)
# 2. tmp/ directory (relative)
# 3. /tmp/ or /private/tmp/ (absolute)
# 4. Top-level .md files (no slash in path, ends with .md)
if printf '%s' "$rel_path" | grep -qE '^codegen/'; then
    exit 0
fi
if printf '%s' "$rel_path" | grep -qE '^tmp/'; then
    exit 0
fi
if printf '%s' "$FILE_PATH" | grep -qE '^(/private)?/tmp/'; then
    exit 0
fi
# Top-level .md files: no directory separator, ends with .md
if printf '%s' "$rel_path" | grep -qE '^[^/]+\.md$'; then
    exit 0
fi

# Combobulate orchestrator may edit OCG sibling repos (committer commits them
# independently — see combobulate/CLAUDE.md "Commit Sibling Repos"). Other
# projects' orchestrators do NOT get this allowance.
if [ "$cwd" = "/Users/almirsarajcic/Projects/AppBuilder/combobulate" ]; then
    case "$FILE_PATH" in
    /Users/almirsarajcic/Areas/Optimum/codegen/*) exit 0 ;;
    /Users/almirsarajcic/Areas/Optimum/context/*) exit 0 ;;
    esac
fi

deny "BLOCKED by orchestrator-no-source-edit: orchestrator must not edit source files directly ($FILE_PATH). Delegate to developer-phoenix-backend / developer-phoenix-frontend / developer-html | developer-hugo | developer-vite."
exit 0
