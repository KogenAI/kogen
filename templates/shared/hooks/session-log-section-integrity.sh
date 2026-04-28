#!/bin/bash
# session-log-section-integrity.sh — PreToolUse Edit hook.
#
# When a subagent edits a session log file (codegen/logging/*.md), the
# new_string must include "## <agent_type> Section" so the session log
# retains the required section header.
#
# Exception: if the section header already exists in the file (follow-up
# edit by the same agent), allow through unconditionally.
#
# Exit codes:
#   0 — allow the tool call
#   2 — block (Claude Code PreToolUse convention; stderr fed back to model)

set -euo pipefail

input=$(cat)

tool_name=$(printf '%s' "$input" | jq -r '.tool_name // ""')
agent_type=$(printf '%s' "$input" | jq -r '.agent_type // ""')

# Debug logging
if [ -n "${COMBOBULATE_HOOKS_DEBUG:-}" ] || [ -n "${COMBOBULATE_SLSI_DEBUG:-}" ]; then
    printf '%s tool=%s agent_type=%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        "$tool_name" "$agent_type" \
        >>/tmp/session-log-section-integrity-debug.log 2>/dev/null || true
fi

# Only gate Edit tool
if [ "$tool_name" != "Edit" ]; then
    exit 0
fi

# No agent_type means orchestrator — not gated here (orchestrator creates files, not edits)
if [ -z "$agent_type" ]; then
    exit 0
fi

file_path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // ""')

# Only gate session log files
if ! printf '%s' "$file_path" | grep -qE 'codegen/logging/.*\.md$'; then
    exit 0
fi

# If the file doesn't exist yet, this is a first write — allow
if [ ! -f "$file_path" ]; then
    exit 0
fi

# If the section header already exists in the file, allow (follow-up edit)
expected_header="## ${agent_type} Section"
if grep -qF "$expected_header" "$file_path" 2>/dev/null; then
    exit 0
fi

# Check if new_string contains the required section header
new_string=$(printf '%s' "$input" | jq -r '.tool_input.new_string // ""')
if printf '%s' "$new_string" | grep -qF "$expected_header"; then
    exit 0
fi

printf 'BLOCKED by session-log-section-integrity: Edit on %s from %s must include "%s" in new_string.\n' \
    "$file_path" "$agent_type" "$expected_header" >&2
exit 2
