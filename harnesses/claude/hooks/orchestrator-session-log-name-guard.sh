#!/bin/bash
# orchestrator-session-log-name-guard.sh — PreToolUse hook: deny non-canonical session-log
# filenames when the orchestrator writes to codegen/logging/.
#
# HOOK-MANIFEST:
# event: PreToolUse
# matcher: Write|Edit
# surface: user_global
# signal: AGENT_TYPE
# role: *
# harnesses: all
# rationale: Denies non-canonical session-log filenames at Write/Edit time so orchestrators see the error immediately rather than at Stop
# GENERATED FROM shared/enforcement/registry.yaml — DO NOT EDIT
#
# Only enforces when AGENT_TYPE is empty AND AGENT_ID is empty (orchestrator level).
# Subagents (any non-empty AGENT_TYPE or AGENT_ID) pass through.
# ops mode (CLAUDE_ROLE=ops / PI_ROLE=ops) bypasses — full access on live boxes.
#
# Only fires on Write|Edit to paths under codegen/logging/.
# Non-logging Writes pass through to orchestrator-no-source-edit.sh.
#
# Allowlist (bash ERE, anchored):
#   codegen/logging/<YYYYMMDD>_<HHMMSS>[_<slug>]_session.md   — single/free-form
#   codegen/logging/<YYYYMMDD>_<HHMMSS>_step<N>_<slug>.md     — step-queue
#   codegen/logging/<YYYYMMDD>_progress.md                     — multi-step progress tracker

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
source "$(dirname "$0")/_role.sh"
parse_input

debug_log orchestrator-session-log-name-guard "tool=$TOOL_NAME agent_type=${AGENT_TYPE:-} agent_id=${AGENT_ID:-} file=${FILE_PATH:-}"

# ops mode bypasses: full access for inspection on live boxes.
_role=$(resolve_role)
[ "$_role" = "ops" ] && exit 0

# Only enforce for orchestrator level (both AGENT_TYPE and AGENT_ID empty).
if [ -n "${AGENT_TYPE:-}" ] || [ -n "${AGENT_ID:-}" ]; then
    debug_log orchestrator-session-log-name-guard "skip: subagent (agent_type=${AGENT_TYPE:-} agent_id=${AGENT_ID:-})"
    exit 0
fi

# Only guard Write|Edit tool(s).
case "$TOOL_NAME" in
Write) ;;
Edit) ;;
*) exit 0 ;;
esac

# Normalise to repo-relative path, then strip any leading ./
rel=$(repo_relative "$FILE_PATH")
rel="${rel#./}"

# Non-logging pre-check: orchestrator legitimately Writes non-log files.
# Pass through so orchestrator-no-source-edit.sh handles them.
if ! printf '%s' "$rel" | grep -qE '^codegen/logging/'; then
    debug_log orchestrator-session-log-name-guard "skip: not a session log path ($rel)"
    exit 0
fi

# Allowlist: canonical session-log name forms.
if printf '%s' "$rel" | grep -qE '^codegen/logging/([0-9]{8}_[0-9]{6}(_[a-z0-9-]+)?_(session|step[0-9]+_[a-z0-9-]+)|[0-9]{8}_progress)\.md$'; then
    debug_log orchestrator-session-log-name-guard "allow: canonical session log ($rel)"
    exit 0
fi

deny "Session log name must be codegen/logging/<YYYYMMDD>_<HHMMSS>_<slug>_session.md (single/multi-pitch) or _step<N>_<slug>.md (stepped) or <YYYYMMDD>_progress.md. Run \`date -u +%Y%m%d_%H%M%S\` for the timestamp, then Write that path. Got: $FILE_PATH"
exit 0
