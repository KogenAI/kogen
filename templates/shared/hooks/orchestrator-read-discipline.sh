#!/bin/bash
# orchestrator-read-discipline.sh — PreToolUse Read hook for orchestrator.
#
# HOOK-MANIFEST:
# event: PreToolUse
# matcher: Read
# surface: user_global
# signal: AGENT_TYPE
# role: *
# harnesses: claude_code
# rationale: CLAUDE_ROLE-keyed; Pi orchestrator has no equivalent read discipline hook
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
#   - codegen/pitches/** (pitch lifecycle dirs — draft/, ready/, shipped/; matches the write-hook surface so /document can read its own drafts)
#
# Subagents (non-empty agent_id) are always allowed through.
#
# Responds to CLAUDE_ROLE (Claude Code), PI_ROLE (PI harness), and CODEX_ROLE
# (Codex) via resolve_role() for the debug/shape/refactor bypass — precedence: CLAUDE_ROLE > PI_ROLE > CODEX_ROLE.
# Primary signal is AGENT_TYPE (set by Claude Code on subagent spawn); role check is secondary.

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
source "$(dirname "$0")/_role.sh"
parse_input

debug_log orchestrator-read-discipline "tool=$TOOL_NAME agent_id=$AGENT_ID agent_type=$AGENT_TYPE"

# Debug, shape, and refactor modes bypass read discipline — investigation and shaping sessions need full access.
_role=$(resolve_role)
if [ "$_role" = "debug" ] || [ "$_role" = "shape" ] || [ "$_role" = "refactor" ]; then
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
# Exclude PROJECT_CONTEXT.md — planner reads it, orchestrator must not.
if printf '%s' "$rel_path" | grep -qE '^codegen/[^/]+\.md$'; then
    bn="${rel_path##*/}"
    if [ "$bn" != "PROJECT_CONTEXT.md" ]; then
        exit 0
    fi
fi

# Allowlist check 4: codegen/pitches/ (draft/ready/shipped) — matches the
# write-hook surface so /document can re-read its own drafts from any session.
if printf '%s' "$rel_path" | grep -qE '^codegen/pitches/'; then
    exit 0
fi

deny "Orchestrator cannot read $FILE_PATH. Delegate to Explore subagent or planner.
Example: delegate to planner with 'Find X in lib/...' — planner reads codebase, returns 100-token answer instead of flooding orchestrator context."
exit 0
