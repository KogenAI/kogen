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

source "$(dirname "$0")/lib/hooks-lib.sh"
parse_input

debug_log llm-pending-sweep "cwd=$CWD"

if [ -n "$CWD" ]; then
    find "$CWD/codegen/llm-pending" -name '*.flag' -mmin +120 -delete 2>/dev/null || true
fi

exit 0
