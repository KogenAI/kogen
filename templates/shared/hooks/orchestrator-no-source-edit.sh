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
#
# Exit codes:
#   0 — allow the tool call
#   2 — block (Claude Code PreToolUse convention; stderr fed back to model)

set -euo pipefail

input=$(cat)

tool_name=$(printf '%s' "$input" | jq -r '.tool_name // ""')
agent_id=$(printf '%s' "$input" | jq -r '.agent_id // ""')

# Debug logging
if [ -n "${COMBOBULATE_HOOKS_DEBUG:-}" ] || [ -n "${COMBOBULATE_ONSE_DEBUG:-}" ]; then
    printf '%s tool=%s agent_id=%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        "$tool_name" "$agent_id" \
        >>/tmp/orchestrator-no-source-edit-debug.log 2>/dev/null || true
fi

# Subagents (non-empty agent_id) — pass through
if [ -n "$agent_id" ]; then
    exit 0
fi

# Get file path (Edit/Write/MultiEdit use file_path, NotebookEdit uses notebook_path)
file_path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.notebook_path // ""')

if [ -z "$file_path" ]; then
    exit 0
fi

# Normalise to a relative path: if the path is absolute and starts with cwd,
# strip the cwd prefix so the relative-path allowlist patterns match correctly.
cwd=$(printf '%s' "$input" | jq -r '.cwd // ""')
if [ -z "$cwd" ]; then
    cwd="${CLAUDE_PROJECT_DIR:-$PWD}"
fi
rel_path="$file_path"
cwd_prefix="${cwd%/}/"
case "$file_path" in
"${cwd_prefix}"*) rel_path="${file_path#"$cwd_prefix"}" ;;
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
if printf '%s' "$file_path" | grep -qE '^(/private)?/tmp/'; then
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
    case "$file_path" in
    /Users/almirsarajcic/Areas/Optimum/codegen/*) exit 0 ;;
    /Users/almirsarajcic/Areas/Optimum/context/*) exit 0 ;;
    esac
fi

printf 'BLOCKED by orchestrator-no-source-edit: orchestrator must not edit source files directly (%s). Delegate to phoenix-developer / static-site-developer / data-layer-developer.\n' \
    "$file_path" >&2
exit 2
