#!/bin/bash
# subagent-read-discipline.sh — PreToolUse Read hook for named subagents.
#
# HOOK-MANIFEST:
# event: PreToolUse
# matcher: Read
# surface: user_global
# signal: AGENT_TYPE
# role: developer-*|reviewer-*|committer|context-curator
# harnesses: claude_code
# rationale: role-keyed read discipline — planner front-loads context, all
#   other named subagents have restricted access to PROJECT_CONTEXT.md,
#   context/*.md, and codegen/pitches/** to enforce the single-sense-organ
#   architecture.
#
# Rules:
#   planner-*       → allow all (planner owns context reads AND pitch reads)
#   context-curator → allow all (curator writes context post-reviewer)
#   committer       → deny PROJECT_CONTEXT.md, context/*.md, codegen/pitches/**
#   developer-*     → deny codegen/pitches/** always (plan is self-contained);
#                     deny PROJECT_CONTEXT.md always;
#                     context/*.md allowed ONLY if path is listed in active
#                     step log's ## Plan block under "Files to touch:"
#   reviewer-*      → deny codegen/pitches/** always;
#                     deny PROJECT_CONTEXT.md always;
#                     context/*.md allowed ONLY if path is listed in active
#                     step log's ## Files Modified block
#   (other / empty) → pass through (orchestrator handled by orchestrator-read-discipline.sh)
#
# Fail-open: if TRANSCRIPT_PATH is missing or step log is not found,
# allow the Read (avoids false-negatives during session initialisation).

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
parse_input

debug_log subagent-read-discipline "tool=$TOOL_NAME agent_type=$AGENT_TYPE file=$FILE_PATH"

# Only gate Read calls.
if [ "$TOOL_NAME" != "Read" ]; then
    exit 0
fi

# Only act on named subagents (non-empty AGENT_TYPE).
if [ -z "$AGENT_TYPE" ]; then
    exit 0
fi

# Empty file_path — let the tool handle it.
if [ -z "$FILE_PATH" ]; then
    exit 0
fi

# Normalise to a relative path (same pattern as orchestrator-read-discipline.sh).
cwd="$CWD"
if [ -z "$cwd" ]; then
    cwd="${CLAUDE_PROJECT_DIR:-$PWD}"
fi
rel_path="$FILE_PATH"
cwd_prefix="${cwd%/}/"
case "$FILE_PATH" in
"${cwd_prefix}"*) rel_path="${FILE_PATH#"$cwd_prefix"}" ;;
esac

# Compute basename.
bn="${rel_path##*/}"

# Determine whether the path is subject to discipline.
is_project_context=0
is_context_dir=0
is_pitch=0

if [ "$bn" = "PROJECT_CONTEXT.md" ]; then
    is_project_context=1
fi

case "$rel_path" in
context/*) is_context_dir=1 ;;
esac

case "$rel_path" in
codegen/pitches/*) is_pitch=1 ;;
esac

# If neither trigger applies, allow immediately.
if [ "$is_project_context" -eq 0 ] && [ "$is_context_dir" -eq 0 ] && [ "$is_pitch" -eq 0 ]; then
    exit 0
fi

# Role dispatch.
case "$AGENT_TYPE" in

planner-*)
    # Planner owns all context reads.
    exit 0
    ;;

context-curator)
    # Curator writes context post-reviewer — full read access.
    exit 0
    ;;

committer)
    # Committer derives commit msg from git diff; never needs context or pitch.
    if [ "$is_pitch" -eq 1 ]; then
        deny "Committer cannot read the pitch — derive commit message from git diff only."
        exit 0
    fi
    if [ "$is_project_context" -eq 1 ]; then
        deny "Committer cannot read PROJECT_CONTEXT.md. Derive commit message from git diff only."
        exit 0
    fi
    if [ "$is_context_dir" -eq 1 ]; then
        deny "Committer cannot read context/*.md. Derive commit message from git diff only."
        exit 0
    fi
    exit 0
    ;;

developer-*)
    # Pitch: always denied — plan is self-contained.
    if [ "$is_pitch" -eq 1 ]; then
        deny "Developer cannot read the pitch — plan is self-contained, use ## Plan in the session log."
        exit 0
    fi

    # PROJECT_CONTEXT.md: always denied — plan is self-contained.
    if [ "$is_project_context" -eq 1 ]; then
        deny "Developer cannot read PROJECT_CONTEXT.md for orientation. Plan is self-contained — use ## Plan in active step log."
        exit 0
    fi

    # context/*.md: allowed only if listed in step log ## Plan → Files to touch.
    if [ "$is_context_dir" -eq 1 ]; then
        step_log=$(session_log_from_transcript)
        if [ -z "$step_log" ] || [ ! -r "$step_log" ]; then
            # Fail-open: no step log found (session init or missing transcript).
            exit 0
        fi

        # Extract ## Plan block (from "## Plan" to next "## " heading).
        plan_block=$(awk '/^## Plan$/{found=1; next} found && /^## /{exit} found{print}' "$step_log")

        # Check if rel_path appears in "Files to touch:" lines within the plan block.
        if printf '%s' "$plan_block" | grep -qF "$rel_path"; then
            exit 0
        fi

        deny "Developer cannot read $FILE_PATH for orientation. Read context/*.md only when the path appears in planner's ## Files to touch as an (EDIT) or (NEW) target."
        exit 0
    fi
    ;;

reviewer-*)
    # Pitch: always denied — reviewer reviews against ## Plan and ## Files Modified.
    if [ "$is_pitch" -eq 1 ]; then
        deny "Reviewer cannot read the pitch — review against ## Plan and ## Files Modified in the active step log."
        exit 0
    fi

    # PROJECT_CONTEXT.md: always denied — reviewer reads ## Files Modified, not raw context.
    if [ "$is_project_context" -eq 1 ]; then
        deny "Reviewer cannot read PROJECT_CONTEXT.md. Check plan fulfillment via ## Plan Goal line in active step log."
        exit 0
    fi

    # context/*.md: allowed only if listed in step log ## Files Modified.
    if [ "$is_context_dir" -eq 1 ]; then
        step_log=$(session_log_from_transcript)
        if [ -z "$step_log" ] || [ ! -r "$step_log" ]; then
            # Fail-open: no step log found.
            exit 0
        fi

        # Extract ## Files Modified block (from heading to next "## " heading).
        files_modified_block=$(awk '/^## Files Modified$/{found=1; next} found && /^## /{exit} found{print}' "$step_log")

        # Check if rel_path appears in ## Files Modified.
        if printf '%s' "$files_modified_block" | grep -qF "$rel_path"; then
            exit 0
        fi

        deny "Reviewer cannot read $FILE_PATH — it is not listed in ## Files Modified. Review only files that developer modified."
        exit 0
    fi
    ;;

*)
    # Unknown AGENT_TYPE — pass through.
    exit 0
    ;;

esac

exit 0
