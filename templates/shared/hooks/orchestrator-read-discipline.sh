#!/bin/bash
# orchestrator-read-discipline.sh — PreToolUse Read hook for orchestrator.
#
# Blocks the orchestrator from reading arbitrary codebase files.
# Orchestrator should delegate exploration to planner or Explore subagent.
#
# Allowed paths:
#   - codegen/logging/* (session logs only)
#   - codegen/rules/roles/orchestrator.md, codegen/rules/shared/git-readonly.md, codegen/rules/_core/* (orchestrator rules)
#   - codegen/rules/stacks/phoenix/_core.md, codegen/rules/stacks/phoenix/orchestrator.md (Phoenix orchestrator rules)
#   - codegen/rules/INDEX.md, codegen/rules/STYLE_GUIDE.md
#   - codegen/*.md (top-level design docs — NOT subdirs like recipes/, templates/, rules/)
#   - codegen/designs/** (design-doc lifecycle dirs — drafts/, ready/, archive/; matches the write-hook surface so /document can read its own drafts)
#
# Subagents (non-empty agent_id) are always allowed through.

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
parse_input

debug_log orchestrator-read-discipline "tool=$TOOL_NAME agent_id=$AGENT_ID agent_type=$AGENT_TYPE"

# Debug mode bypasses read discipline — investigation sessions need full access.
if [ "${CLAUDE_ROLE:-}" = "debug" ]; then
    exit 0
fi

# Only gate Read calls.
if [ "$TOOL_NAME" != "Read" ]; then
    exit 0
fi

# Subagents (non-empty agent_id) — pass through.
if [ -n "$AGENT_ID" ]; then
    exit 0
fi

# Only apply to orchestrator (empty agent_type = orchestrator level).
# Planner and other named agents have non-empty AGENT_TYPE.
if [ -n "$AGENT_TYPE" ]; then
    exit 0
fi

# Empty file_path — let the tool handle it.
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

# Allowlist check 1: codegen/logging/ (session logs)
if printf '%s' "$rel_path" | grep -qE '^codegen/logging/'; then
    exit 0
fi

# Allowlist check 2: orchestrator rule files (roles/orchestrator.md, shared/git-readonly.md, stacks/phoenix/{_core,orchestrator}.md, _core/*, INDEX.md, STYLE_GUIDE.md)
if printf '%s' "$rel_path" | grep -qE '^codegen/rules/(roles/orchestrator\.md|shared/git-readonly\.md|stacks/phoenix/(_core|orchestrator)\.md|_core/[^/]+\.md|INDEX\.md|STYLE_GUIDE\.md)$'; then
    exit 0
fi

# Allowlist check 2b: build-runtime rules for user-app orchestrators
if printf '%s' "$rel_path" | grep -qE '^codegen/rules/build-runtime/[^/]+\.md$'; then
    exit 0
fi

# Allowlist check 3: codegen/*.md (top-level design docs only — no subdirs)
if printf '%s' "$rel_path" | grep -qE '^codegen/[^/]+\.md$'; then
    exit 0
fi

# Allowlist check 4: codegen/designs/ (drafts/ready/archive) — matches the
# write-hook surface so /document can re-read its own drafts from any session.
if printf '%s' "$rel_path" | grep -qE '^codegen/designs/'; then
    exit 0
fi

deny "Orchestrator cannot read $FILE_PATH. Delegate to Explore subagent or planner.
Example: delegate to planner with 'Find X in lib/...' — planner reads codebase, returns 100-token answer instead of flooding orchestrator context."
exit 0
