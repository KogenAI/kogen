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
# rationale: Claude Code per-call Read inspector; Pi uses load-gate tool restriction
# registration only (hand-authored body) — the registry entry for this hook
# is `kind: registration`, which emits ONLY the settings.json wiring; the
# check logic below is NOT generated and is safe to hand-edit.
#
# Rules:
#   planner-*       → allow all (planner owns context reads AND pitch reads)
#   context-curator → allow all (curator writes context post-reviewer)
#   committer       → deny PROJECT_CONTEXT.md, context/*.md, codegen/pitches/**
#   developer-*     → deny codegen/pitches/** always (plan is self-contained);
#                     deny PROJECT_CONTEXT.md always;
#                     context/*.md allowed ONLY if path is listed in the
#                     PLANNER's typed {"ev":"files_to_touch",...} event in the
#                     active cycle log (written via
#                     `codegen-log append <role> --files-to-touch @-`)
#   reviewer-*      → deny codegen/pitches/** always;
#                     deny PROJECT_CONTEXT.md always;
#                     context/*.md allowed ONLY if path is listed in the
#                     DEVELOPER's typed {"ev":"files_modified",...} event in
#                     the active cycle log (written via
#                     `codegen-log append <role> --files-modified @-`)
#   (other / empty) → pass through (orchestrator handled by orchestrator-read-discipline.sh)
#
# The field is read from its AUTHOR's event (planner's files_to_touch,
# developer's files_modified) — never from the calling role's own event.
# This is a typed JSONL event, never re-parsed out of a role's free-form
# body prose (session-log.md § the body is opaque, never re-parsed as
# structure).
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
        deny "Developer cannot read the pitch — when a ## Plan is present it is self-contained, use it from the session log; when no ## Plan is present, the pitch text is already inlined in your delegation prompt."
        exit 0
    fi

    # PROJECT_CONTEXT.md: always denied — plan is self-contained.
    if [ "$is_project_context" -eq 1 ]; then
        deny "Developer cannot read PROJECT_CONTEXT.md for orientation. When a ## Plan is present it is self-contained — use it from the active step log; when absent, the pitch text already inlined in your prompt is the complete scope."
        exit 0
    fi

    # context/*.md: allowed only if listed in the PLANNER's typed
    # files_to_touch event.
    if [ "$is_context_dir" -eq 1 ]; then
        step_log=$(session_log_from_transcript)
        if [ -z "$step_log" ] || [ ! -r "$step_log" ]; then
            # ANTI-WEDGE FAIL-OPEN (fail-loud-rule exemption): the step log
            # may not yet exist during session init, or the transcript may
            # lag the live write (async flush). Denying the Read here would
            # wedge legitimate early-session orientation reads. Sanctioned
            # fail-open survivor of the fail-closed-everywhere ruling —
            # intentional, commented, justified.
            exit 0
        fi

        # Read the PLANNER's typed files_to_touch event, not the developer's
        # own body — the field is read from its AUTHOR's event.
        if jq -e --arg p "$rel_path" \
            'select(.ev=="files_to_touch" and (.role | startswith("planner"))) | .files[]? | select(. == $p)' \
            "$step_log" >/dev/null 2>&1; then
            exit 0
        fi

        deny "Developer cannot read $FILE_PATH for orientation. Read context/*.md only when the path appears in planner's files_to_touch event as an (EDIT) or (NEW) target."
        exit 0
    fi
    ;;

reviewer-*)
    # Pitch: always denied — reviewer reviews against ## Plan and ## Files Modified.
    if [ "$is_pitch" -eq 1 ]; then
        deny "Reviewer cannot read the pitch — review against ## Plan (when present) and ## Files Modified in the active step log; when no ## Plan was threaded (plan-less stack), report plan-fulfillment checks N/A rather than reading the pitch."
        exit 0
    fi

    # PROJECT_CONTEXT.md: always denied — reviewer reads ## Files Modified, not raw context.
    if [ "$is_project_context" -eq 1 ]; then
        deny "Reviewer cannot read PROJECT_CONTEXT.md. Check plan fulfillment via ## Plan Goal line in active step log when present; when absent, report N/A — no ## Plan in the active step log (plan-less stack)."
        exit 0
    fi

    # context/*.md: allowed only if listed in the DEVELOPER's typed
    # files_modified event.
    if [ "$is_context_dir" -eq 1 ]; then
        step_log=$(session_log_from_transcript)
        if [ -z "$step_log" ] || [ ! -r "$step_log" ]; then
            # ANTI-WEDGE FAIL-OPEN (fail-loud-rule exemption): the step log
            # may not yet exist during session init, or the transcript may
            # lag the live write (async flush). Denying the Read here would
            # wedge legitimate early-session orientation reads. Sanctioned
            # fail-open survivor of the fail-closed-everywhere ruling —
            # intentional, commented, justified.
            exit 0
        fi

        # Read the DEVELOPER's typed files_modified event, not the
        # reviewer's own body — the field is read from its AUTHOR's event.
        if jq -e --arg p "$rel_path" \
            'select(.ev=="files_modified" and (.role | startswith("developer"))) | .files[]? | select(. == $p)' \
            "$step_log" >/dev/null 2>&1; then
            exit 0
        fi

        deny "Reviewer cannot read $FILE_PATH — it is not listed in developer's files_modified event. Review only files that developer modified."
        exit 0
    fi
    ;;

*)
    # Unknown AGENT_TYPE — pass through.
    exit 0
    ;;

esac

exit 0
