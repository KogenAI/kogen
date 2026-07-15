#!/bin/bash
# curator-before-committer.sh — PreToolUse Agent hook.
#
# HOOK-MANIFEST:
# event: PreToolUse
# matcher: Agent
# surface: user_global
# signal: none
# role: *
# harnesses: all
# registration only (hand-authored body) — the registry entry for this hook
# is `kind: registration`, which emits ONLY the settings.json wiring; the
# check logic below is NOT generated and is safe to hand-edit.
#
# Blocks committer spawn when reviewer has run but context-curator has not.
# Enforces the invariant: reviewer → context-curator → committer.
#
# Logic:
#   If subagent_type == "committer"
#     AND cycle-state.json state == "REVIEWED"
#   → deny with explanation
#
# Fail-open: if no cycle-state.json or state absent, allow (can't determine state).
# All other subagent types: allow unconditionally.

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
# shellcheck disable=SC1091
source "$(dirname "$0")/lib/cycle-state.sh"
parse_input

# Only guard the Agent tool (subagent spawn).
if [ "$TOOL_NAME" != "Agent" ]; then
    exit 0
fi

subagent_type=$(printf '%s' "$RAW_INPUT" | jq -r '.tool_input.subagent_type // ""' 2>/dev/null)

debug_log curator-before-committer "subagent_type=$subagent_type"

# Only inspect committer spawns.
if [ "$subagent_type" != "committer" ]; then
    exit 0
fi

# Locate active step log from transcript.
log_file=$(session_log_from_transcript)

if [ -z "$log_file" ] || [ ! -r "$log_file" ]; then
    debug_log curator-before-committer "fail-open: no active step log"
    exit 0
fi

debug_log curator-before-committer "log=$log_file"

project_dir="${CWD:-${CLAUDE_PROJECT_DIR:-$PWD}}"
cs_state=$(cycle_state_get "$project_dir")

debug_log curator-before-committer "cs_state=$cs_state"

# Block only when cycle-state is REVIEWED (reviewer ran, curator has not).
if [ "$cs_state" = "REVIEWED" ]; then
    deny "BLOCKED: context-curator must run before committer. Reviewer ran (cycle-state=REVIEWED), curator has not. Delegate to context-curator first."
    exit 0
fi

exit 0
