#!/bin/bash
# curator-before-committer.sh — PreToolUse Agent hook.
#
# HOOK-MANIFEST:
# event: PreToolUse
# matcher: Agent
# surface: user_global
# signal: none
# role: *
# harnesses: claude_code
# rationale: Agent tool not present in Pi harness
# GENERATED FROM shared/enforcement/registry.yaml — DO NOT EDIT
#
# Blocks committer spawn when reviewer has run but context-curator has not.
# Enforces the invariant: reviewer → context-curator → committer.
#
# Logic:
#   If subagent_type == "committer"
#     AND session log has a ## reviewer-* Section
#     AND session log has NO ## context-curator Section
#   → deny with explanation
#
# Fail-open: if no session log found, allow (can't determine state).
# All other subagent types: allow unconditionally.

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
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

# Check if reviewer has run.
has_reviewer=0
if grep -qE '^## reviewer-.+ Section|^## reviewer-phoenix Section|^## reviewer-static Section' "$log_file" 2>/dev/null; then
    has_reviewer=1
fi

# Check if context-curator has run.
has_curator=0
if grep -qE '^## context-curator Section' "$log_file" 2>/dev/null; then
    has_curator=1
fi

debug_log curator-before-committer "has_reviewer=$has_reviewer has_curator=$has_curator"

# Block only when reviewer ran but curator did not.
if [ "$has_reviewer" = "1" ] && [ "$has_curator" = "0" ]; then
    deny "BLOCKED: context-curator must run before committer. Reviewer ran, curator has not. Delegate to context-curator first."
    exit 0
fi

exit 0
