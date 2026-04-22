#!/bin/bash
# code-reviewer-guard.sh — PreToolUse hook for code-reviewer
#
# Blocks all mutating tools when the active agent is "code-reviewer".
# The code-reviewer is a read-only analysis role: Read, Grep, Glob only.
# All other agents pass through unconditionally.
#
# Exit codes:
#   0 — allow the tool call
#   2 — block the tool call (Claude Code PreToolUse convention)

set -euo pipefail

input=$(cat)

# Parse fields from PreToolUse stdin JSON
tool_name=$(printf '%s' "$input" | jq -r '.tool_name // ""')
agent_name=$(printf '%s' "$input" | jq -r '.agent_name // ""')

# Debug logging (opt-in via env var)
if [ -n "${COMBOBULATE_CR_DEBUG:-}" ]; then
    printf '%s tool=%s agent=%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        "$tool_name" "$agent_name" \
        >>/tmp/cr-guard-debug.log 2>/dev/null || true
fi

# Only gate code-reviewer; allow all other agents unconditionally
if [ "$agent_name" != "code-reviewer" ]; then
    exit 0
fi

# ── Tool-level blocks ─────────────────────────────────────────────────────────

case "$tool_name" in
Bash)
    printf 'BLOCKED by cr-guard: tool Bash forbidden for code-reviewer (read-only role)\n' >&2
    exit 2
    ;;
Write)
    printf 'BLOCKED by cr-guard: tool Write forbidden for code-reviewer (read-only role)\n' >&2
    exit 2
    ;;
Edit)
    file_path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // ""')
    if printf '%s' "$file_path" | grep -qE 'codegen/logging/[^/]+_(session|step[0-9]+_[^/]+)\.md$'; then
        exit 0
    fi
    printf 'BLOCKED by cr-guard: code-reviewer may not edit files outside session logs: %s\n' "$file_path" >&2
    exit 2
    ;;
MultiEdit)
    printf 'BLOCKED by cr-guard: tool MultiEdit forbidden for code-reviewer (read-only role)\n' >&2
    exit 2
    ;;
Monitor)
    printf 'BLOCKED by cr-guard: tool Monitor forbidden for code-reviewer (read-only role)\n' >&2
    exit 2
    ;;
esac

exit 0
