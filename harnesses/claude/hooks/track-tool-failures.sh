#!/bin/bash
# track-tool-failures.sh — PostToolUseFailure hook (matcher: *).
#
# HOOK-MANIFEST:
# event: PostToolUseFailure
# matcher: *
# surface: user_global
# signal: AGENT_TYPE
# role: *
# harnesses: all
# registration only (hand-authored body) — the registry entry for this hook
# is `kind: registration`, which emits ONLY the settings.json wiring; the
# check logic below is NOT generated and is safe to hand-edit.
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
# Each line: {"ts":"<ISO>","tool":"<name>","error":"<msg>","command":"<cmd>"}
# "command" is .tool_input.command (Bash calls only — empty for non-Bash
# tools such as Read/Edit, whose tool_input has no "command" key) so a
# failure names the call that caused it, not just the tool name + error.
#
# Safety rules:
#   - Exits 0 in all cases — observability only, never blocks.
#   - Orchestrator failures (empty agent_id) tracked under "_orchestrator".
#   - Ledger dir created on first write.
#   - Stale ledgers (>7 days) GC'd at start.

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
parse_input

# Pull .tool_response.error (PostToolUseFailure payload). Falls back to
# .error for harness variants. Truncate to 4kB to avoid runaway ledger growth.
ERROR_MSG=$(printf '%s' "$RAW_INPUT" | jq -r '.tool_response.error // .error // ""' 2>/dev/null | head -c 4096)

# COMMAND is parsed by parse_input (hooks-lib.sh) from .tool_input.command —
# empty string for non-Bash tools. Truncate to 4kB, same cap as ERROR_MSG.
COMMAND_MSG=$(printf '%s' "${COMMAND:-}" | head -c 4096)

debug_log track-tool-failures "tool=$TOOL_NAME agent_id=$AGENT_ID session=$SESSION_ID err_len=${#ERROR_MSG}"

ledger_dir="$HOME/.claude/tool-failures"
mkdir -p "$ledger_dir"

# GC stale ledgers older than 7 days.
find "$ledger_dir" -maxdepth 1 -name "*.jsonl" -mtime +7 -delete 2>/dev/null || true

agent_slug="${AGENT_ID:-_orchestrator}"
session_slug="${SESSION_ID:-nosession}"
ledger="${ledger_dir}/${session_slug}_${agent_slug}.jsonl"

ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
jq -nc \
    --arg ts "$ts" \
    --arg tool "$TOOL_NAME" \
    --arg error "$ERROR_MSG" \
    --arg command "$COMMAND_MSG" \
    '{ts: $ts, tool: $tool, error: $error, command: $command}' \
    >>"$ledger" 2>/dev/null || true

debug_log track-tool-failures "appended ledger=$ledger"

# Durable codegen-local copy (no GC). Only when CWD is the codegen repo
# (sentinel: shared/enforcement/registry.yaml present). Downstream apps
# lack this sentinel → no local write, no dirtied tree. || true: never block.
if [ -n "${CWD:-}" ] && [ -f "$CWD/shared/enforcement/registry.yaml" ]; then
    local_dir="$CWD/codegen/logging/failures"
    mkdir -p "$local_dir" 2>/dev/null || true
    jq -nc \
        --arg ts "$ts" \
        --arg tool "$TOOL_NAME" \
        --arg error "$ERROR_MSG" \
        --arg agent "$agent_slug" \
        --arg command "$COMMAND_MSG" \
        '{ts: $ts, tool: $tool, error: $error, agent: $agent, command: $command}' \
        >>"$local_dir/${session_slug}.jsonl" 2>/dev/null || true
    debug_log track-tool-failures "appended local=$local_dir/${session_slug}.jsonl"
fi

exit 0
