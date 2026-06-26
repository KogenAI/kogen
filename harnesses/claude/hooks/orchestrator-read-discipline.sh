#!/bin/bash
# orchestrator-read-discipline.sh — PreToolUse Read|Bash hook for orchestrator.
#
# HOOK-MANIFEST:
# event: PreToolUse
# matcher: Read|Bash
# surface: user_global
# signal: AGENT_TYPE
# role: *
# harnesses: all
# GENERATED FROM shared/enforcement/registry.yaml — DO NOT EDIT
#
# Blocks the orchestrator from:
#   1. Reading arbitrary codebase files (Read tool — path allowlist enforced)
#   2. Investigating via Bash with exploration verbs: find, grep, rg, ls, tree, cat
#      (denial anchored on LEADING token only so git/make/date/cp pass through)
#
# Orchestrator should delegate exploration to the planner subagent (planner-phoenix / planner-static).
#
# Read — Allowed paths:
#   - codegen/logging/* (session logs only)
#   - codegen/rules/roles/orchestrator.md, codegen/rules/shared/git-readonly.md, codegen/rules/_core/* (orchestrator rules)
#   - codegen/rules/stacks/phoenix/_core.md, codegen/rules/stacks/phoenix/orchestrator.md (Phoenix orchestrator rules)
#   - codegen/rules/INDEX.md, codegen/rules/STYLE_GUIDE.md
#   - codegen/*.md (top-level design docs — NOT subdirs like recipes/, templates/, rules/)
#   - codegen/pitches/** (pitch lifecycle dirs — draft/, ready/, shipped/; matches the write-hook surface so /document can read its own drafts)
#   - codegen/gate-pending/* (gate verdict JSON — orchestrator reads gate result after gate runs)
#
# Bash — Denied when command LEADS with: find | grep | rg | ls | tree | cat
#   Any other Bash (git status/diff, git log, make gate-status, date, cp, log redirects) → allowed.
#
# Subagents (non-empty agent_id) are always allowed through.
#
# Responds to CLAUDE_ROLE (Claude Code) and PI_ROLE (PI harness)
# via resolve_role() for the debug/shape/ops bypass — precedence: CLAUDE_ROLE > PI_ROLE.
# Primary signal is AGENT_TYPE (set by Claude Code on subagent spawn); role check is secondary.

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
source "$(dirname "$0")/_role.sh"
parse_input

debug_log orchestrator-read-discipline "tool=$TOOL_NAME agent_id=$AGENT_ID agent_type=$AGENT_TYPE"

# Debug, shape, and ops modes bypass read discipline — investigation, shaping, and ops sessions need full access.
_role=$(resolve_role)
if [ "$_role" = "debug" ] || [ "$_role" = "shape" ] || [ "$_role" = "ops" ]; then
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

# Branch on tool name.
if [ "$TOOL_NAME" = "Bash" ]; then
    _cmd="${COMMAND:-}"

    # Deny any Bash command that touches the session transcript — the orchestrator
    # has no legitimate reason to read, write, or forge the .jsonl transcript.
    # Forging JSONL to trick step-log guards is the demonstrated exploit.
    if printf '%s' "$_cmd" | grep -qE '(\$TRANSCRIPT_PATH|\.jsonl|\.claude/projects/)'; then
        deny "Orchestrator must not touch the session transcript via Bash. Delegate transcript-dependent work or comply with the hook denial instead."
    fi

    # Deny when command leads with an exploration verb.
    # Anchor on leading token only — never substring — so git log --grep=, make gate-status, date, cp stay allowed.
    if printf '%s' "$_cmd" | grep -qE '^[[:space:]]*(find|grep|rg|ls|tree|cat)\b'; then
        # Extract the leading verb for the deny message.
        _verb=$(printf '%s' "$_cmd" | grep -oE '(find|grep|rg|ls|tree|cat)' | head -1 || true)
        deny "Orchestrator cannot investigate via Bash (\`${_verb}\`). For files you may read directly, use the Read tool; otherwise delegate to planner.
Example: delegate to planner with 'Find X in lib/...' — planner reads/greps codebase, returns 100-token answer instead of flooding orchestrator context."
    fi
    exit 0
fi

# Read tool — apply path allowlist.
if [ "$TOOL_NAME" != "Read" ]; then
    exit 0
fi

# Empty file_path — let the tool handle it.
if [ -z "$FILE_PATH" ]; then
    exit 0
fi

# Normalise to a repo-relative path so allowlist patterns match both relative
# and abs-in-cwd forms (deliberate loosening — see session-log.md § Path Discipline).
rel_path=$(repo_relative "$FILE_PATH")

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

# Allowlist check 5: codegen/gate-pending/ (orchestrator reads gate verdict JSON)
if printf '%s' "$rel_path" | grep -qE '^codegen/gate-pending/'; then
    exit 0
fi

deny "Orchestrator cannot read $FILE_PATH. Delegate to the planner subagent (planner-phoenix / planner-static).
Example: delegate to planner with 'Find X in lib/...' — planner reads codebase, returns 100-token answer instead of flooding orchestrator context."
exit 0
