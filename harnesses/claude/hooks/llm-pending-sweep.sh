#!/bin/bash
# llm-pending-sweep.sh — Stop event hook.
#
# HOOK-MANIFEST:
# event: Stop
# matcher: *
# surface: user_global
# signal: none
# role: *
# harnesses: all
# GENERATED FROM shared/enforcement/registry.yaml — DO NOT EDIT
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
    REPO_ROOT=$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null || echo "$CWD")
    find "$REPO_ROOT/codegen/llm-pending" -name '*.flag' -mmin +120 -delete 2>/dev/null || true
fi

exit 0
