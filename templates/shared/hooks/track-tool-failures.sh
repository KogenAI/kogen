#!/bin/bash
# track-tool-failures.sh — PostToolUseFailure hook (matcher: *).
#
# Records every tool failure into a per-subagent JSONL ledger so the
# orchestrator (or later analysis) can detect the "developer dropped a
# tool error and proceeded" anti-pattern without scraping transcripts.
#
# Replaces the previous transcript-scrape approach with a direct hook
# event: PostToolUseFailure fires on any tool that exits with an error,
# carrying TOOL_NAME, AGENT_*, SESSION_ID, plus the .tool_response.error
# payload from Claude Code.
#
# Ledger location: ~/.claude/tool-failures/<session_id>_<agent_id>.jsonl
# Each line: {"ts":"<ISO>","tool":"<name>","error":"<msg>"}
#
# Safety rules:
#   - Exits 0 in all cases — observability only, never blocks.
#   - Orchestrator failures (empty agent_id) tracked under "_orchestrator".
#   - Ledger dir created on first write.
#   - Stale ledgers (>7 days) GC'd at start, mirroring post-developer-format.sh.

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
parse_input

# Pull .tool_response.error (PostToolUseFailure payload). Falls back to
# .error for harness variants. Truncate to 4kB to avoid runaway ledger growth.
ERROR_MSG=$(printf '%s' "$RAW_INPUT" | jq -r '.tool_response.error // .error // ""' 2>/dev/null | head -c 4096)

debug_log track-tool-failures "tool=$TOOL_NAME agent_id=$AGENT_ID session=$SESSION_ID err_len=${#ERROR_MSG}"

ledger_dir="$HOME/.claude/tool-failures"
mkdir -p "$ledger_dir"

# GC stale ledgers older than 7 days (mirror post-developer-format.sh pattern).
find "$ledger_dir" -maxdepth 1 -name "*.jsonl" -mtime +7 -delete 2>/dev/null || true

agent_slug="${AGENT_ID:-_orchestrator}"
session_slug="${SESSION_ID:-nosession}"
ledger="${ledger_dir}/${session_slug}_${agent_slug}.jsonl"

ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
jq -nc \
    --arg ts "$ts" \
    --arg tool "$TOOL_NAME" \
    --arg error "$ERROR_MSG" \
    '{ts: $ts, tool: $tool, error: $error}' \
    >>"$ledger" 2>/dev/null || true

debug_log track-tool-failures "appended ledger=$ledger"

exit 0
