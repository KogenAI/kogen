#!/bin/bash
# llm-pending-sweep.sh — Stop event hook.
#
# Sweeps stale LLM-pending flag files (older than 120 minutes) from the
# codegen/llm-pending/ sidecar directory. Old flags are noise — the dev
# session that wrote them ended long ago. Fresh flags survive the sweep
# and remain for the orchestrator's `make llm-pending` to read.
#
# Always exits 0 — this is a cleanup hook, not a gate.

set -u

input=$(cat)

cwd=$(printf '%s' "$input" | jq -r '.cwd // ""')

# Debug logging
if [ -n "${COMBOBULATE_HOOKS_DEBUG:-}" ] || [ -n "${COMBOBULATE_LPS_DEBUG:-}" ]; then
    printf '%s cwd=%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        "$cwd" \
        >>/tmp/llm-pending-sweep-debug.log 2>/dev/null || true
fi

if [ -n "$cwd" ]; then
    find "$cwd/codegen/llm-pending" -name '*.flag' -mmin +120 -delete 2>/dev/null || true
fi

exit 0
