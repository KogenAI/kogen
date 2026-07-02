#!/bin/bash
# curator-format.sh — SubagentStop hook for context-curator subagent.
#
# HOOK-MANIFEST:
# event: SubagentStop
# matcher: context-curator
# surface: user_global
# signal: AGENT_TYPE
# role: context-curator
# harnesses: all
# GENERATED FROM shared/enforcement/registry.yaml — DO NOT EDIT
#
# Purpose: when the context-curator subagent stops, run `make format` so
# curator-authored markdown in context/** and codegen/rules/** is formatted
# before the committer stages it.
#
# This is a fix-up hook, not a gate: always exits 0.
# No ledger, no git-diff, no LLM-signal, no per-repo bucketing — curator
# output is markdown and `make format` handles the whole tree idempotently.

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
# shellcheck disable=SC1091
source "$(dirname "$0")/lib/cycle-state.sh"
parse_input

agent_type="$AGENT_TYPE"
project_dir="$CWD"

# Loop guard — bail if a previous SubagentStop hook already fired for this stop.
if [ "$STOP_HOOK_ACTIVE" = "true" ]; then
    exit 0
fi

# AGENT_TYPE gate — only run for context-curator.
case "$agent_type" in
context-curator) ;;
*)
    debug_log curator-format "skip (not context-curator: agent_type=$agent_type)"
    exit 0
    ;;
esac

# Fall back to env var / pwd if cwd field missing.
if [ -z "$project_dir" ]; then
    project_dir="${CLAUDE_PROJECT_DIR:-$PWD}"
fi

debug_log curator-format "fired cwd=$project_dir"

cd "$project_dir" 2>/dev/null || {
    debug_log curator-format "could not cd to project_dir, exiting"
    exit 0
}

# Run make format if a format target exists.
if grep -q '^format:' "$project_dir/Makefile" 2>/dev/null; then
    debug_log curator-format "make format target found — running"
    (cd "$project_dir" && make format >/dev/null 2>&1) || debug_log curator-format "make format had errors (non-fatal)"
else
    debug_log curator-format "no make format target — skipping"
fi

# Stamp CURATED so downstream readers can detect the curation stage.
log_file=$(session_log_from_transcript)
write_cycle_state "CURATED" "${log_file:-}" "${SESSION_ID:-unknown}" "" "$project_dir"
debug_log curator-format "stamped CURATED"

exit 0
