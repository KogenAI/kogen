#!/bin/bash
# step-log-section-before-spawn.sh — PreToolUse Agent hook.
#
# HOOK-MANIFEST:
# event: PreToolUse
# matcher: Agent
# surface: user_global
# signal: CLAUDE_ROLE_FAMILY
# role: *
# harnesses: all
# GENERATED FROM shared/enforcement/registry.yaml — DO NOT EDIT
#
# Blocks subagent spawn when (a) no step log has been written yet or
# (b) the required section header for the spawned agent is absent from the log.
#
# Logic:
#   If TOOL_NAME != "Agent" → exit 0 (not our concern)
#   Resolve launcher role via resolve_role(); bypass for debug/shape/ops.
#   Read subagent_type from tool_input.
#   Map subagent_type → expected header:
#     planner-* → "## Plan"
#     anything else → "## <subagent_type> Section"
#   Locate step log via session_log_from_transcript.
#   If no log found → deny "create step log FIRST before spawning <type>"
#   If log exists but expected header absent → deny naming the missing header
#   Else → allow
#
# Fail-open: if transcript is unreadable, allow (cannot determine state).
# Only blocks when state is KNOWN to be missing.

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
source "$(dirname "$0")/_role.sh"
parse_input

# Only guard the Agent tool (subagent spawn).
if [ "$TOOL_NAME" != "Agent" ]; then
    exit 0
fi

_role=$(resolve_role)
debug_log step-log-section-before-spawn "role=$_role"
if [ "$_role" = "debug" ] || [ "$_role" = "shape" ] || [ "$_role" = "ops" ]; then
    debug_log step-log-section-before-spawn "investigative mode bypass: allowing Agent spawn"
    exit 0
fi

subagent_type=$(printf '%s' "$RAW_INPUT" | jq -r '.tool_input.subagent_type // ""' 2>/dev/null)

debug_log step-log-section-before-spawn "subagent_type=$subagent_type"

# Forbidden-type skip guard — defer to operator-subagent-allowlist for types it will deny.
# These 5 cases exactly mirror the allowlist's build-mode forbidden set:
#   Plan, general-purpose, statusline-setup — built-in types denied always
#   "" (empty) — denied defensively by allowlist
#   Explore — denied in build mode (only allowed under debug/shape/ops, already bypassed above)
if [ "$subagent_type" = "Plan" ] || [ "$subagent_type" = "general-purpose" ] ||
    [ "$subagent_type" = "statusline-setup" ] || [ -z "$subagent_type" ] ||
    [ "$subagent_type" = "Explore" ]; then
    debug_log step-log-section-before-spawn "forbidden type $subagent_type — deferring to operator-subagent-allowlist"
    exit 0
fi

# Map subagent_type → expected header in step log.
# planner-* → "## Plan" (session-log.md planner exception)
# all others → "## <subagent_type> Section"
case "$subagent_type" in
planner*)
    need="## Plan"
    ;;
*)
    need="## ${subagent_type} Section"
    ;;
esac

debug_log step-log-section-before-spawn "need=$need"

# Transcript readable guard — fail-open when transcript is unreadable.
if [ -z "${TRANSCRIPT_PATH:-}" ] || [ ! -r "$TRANSCRIPT_PATH" ]; then
    debug_log step-log-section-before-spawn "fail-open: transcript unreadable"
    exit 0
fi

# Locate active step log from transcript.
log=$(session_log_from_transcript)

debug_log step-log-section-before-spawn "log=$log"

# No log found → orchestrator skipped step-0 log creation.
if [ -z "$log" ]; then
    deny "BLOCKED: no step log found in transcript. Create the step log FIRST before spawning ${subagent_type}. Step 0 is non-negotiable: Write the step log skeleton, THEN insert the ## ${subagent_type} Section header, THEN spawn. Do not investigate why this fired — do the above and retry."
    exit 0
fi

# Distinguish absent (denied/never-created) from exists-but-unreadable (transient).
if [ ! -e "$log" ]; then
    deny "BLOCKED: step log was referenced in the transcript but was never created — a denied or failed Write leaves no file on disk. Create the step log for real before spawning. Do not investigate why this fired — do the above and retry."
    exit 0
fi
# Log exists but is momentarily unreadable (genuine transient) → fail-open.
if [ ! -r "$log" ]; then
    debug_log step-log-section-before-spawn "fail-open: log exists but not readable at $log"
    exit 0
fi

# Check that the expected header is present.
if grep -qF "$need" "$log" 2>/dev/null; then
    debug_log step-log-section-before-spawn "allow: header present"
    exit 0
fi

# Header absent → block and name the missing header.
deny "BLOCKED: missing section header in step log before spawning ${subagent_type}. Edit the step log to append '${need}' immediately before this Agent() call, then retry. Do not investigate why this fired — do the above and retry."
exit 0
