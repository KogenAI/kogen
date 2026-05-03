#!/bin/bash
# codex-inspector-write-guard.sh — PreToolUse hook for Codex Inspector
#
# Blocks apply_patch tool calls when invoked for a Codex Inspector session.
# apply_patch is Codex's primary write surface — Inspector is read-only.
#
# Modeled on inspector-write-guard.sh but gates on apply_patch specifically,
# since Codex does not have Write/Edit/MultiEdit/NotebookEdit.
#
# Exit codes:
#   0 — allow the tool call
#   2 — block the tool call (Codex PreToolUse convention)

set -euo pipefail

input=$(cat)

tool_name=$(printf '%s' "$input" | jq -r '.tool_name // ""')

if printf '%s' "$tool_name" | grep -qE '^apply_patch$'; then
    printf 'BLOCKED by codex-inspector-write-guard: apply_patch is forbidden for Inspector (read-only role)\n' >&2
    exit 2
fi

exit 0
