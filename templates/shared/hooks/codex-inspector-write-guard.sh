#!/bin/bash
# codex-inspector-write-guard.sh — PreToolUse hook for Codex Inspector
#
# HOOK-MANIFEST:
# event: PreToolUse
# matcher: apply_patch
# surface: per_call_inspector
# signal: CODEX_ROLE
# role: codex-inspector
#
# Blocks apply_patch tool calls when invoked for a Codex Inspector session.
# apply_patch is Codex's primary write surface — Inspector is read-only.

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
parse_input

# Only active when CODEX_ROLE=inspector.
[ "${CODEX_ROLE:-}" = "inspector" ] || exit 0

if printf '%s' "$TOOL_NAME" | grep -qE '^apply_patch$'; then
    deny "BLOCKED by codex-inspector-write-guard: apply_patch is forbidden for Inspector (read-only role)"
    exit 0
fi

exit 0
