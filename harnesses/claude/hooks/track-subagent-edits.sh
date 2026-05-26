#!/bin/bash
# track-subagent-edits.sh — PreToolUse hook (matcher: Edit|Write|MultiEdit).
#
# HOOK-MANIFEST:
# event: PreToolUse
# matcher: Edit|Write|MultiEdit|NotebookEdit
# surface: user_global
# signal: AGENT_TYPE
# role: *
# harnesses: all
#
# Records each file path written/edited by a subagent into a per-subagent
# ledger so post-developer-format.sh can format ONLY that subagent's files.
#
# Solves the parallel-dev collision in post-developer-format.sh: the old
# `git diff` approach was per-repo, not per-subagent. Parallel devs would
# trip each other's in-flight edits.
#
# Ledger location: ~/.claude/post-format/<session_id>_<agent_id>.txt
# Each line: one absolute file path.
#
# Safety rules:
#   - Exits 0 (allow) in all cases — this hook never blocks.
#   - Orchestrator edits skipped (empty agent_id).
#   - Non-file tools skipped (empty file_path).
#   - Ledger dir created on first write.
#   - Stale ledgers GC'd weekly by `ocg setup` via:
#       find ~/.claude/post-format -mtime +7 -delete

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
parse_input

debug_log track-subagent-edits "tool=$TOOL_NAME agent_id=$AGENT_ID session=$SESSION_ID file=$FILE_PATH"

# Only gate Edit/Write/MultiEdit tools.
case "$TOOL_NAME" in
Edit | Write | MultiEdit | NotebookEdit) ;;
*)
    exit 0
    ;;
esac

# Skip orchestrator (empty agent_id).
if [ -z "$AGENT_ID" ]; then
    exit 0
fi

# Skip if no file path.
if [ -z "$FILE_PATH" ]; then
    exit 0
fi

# Write file path to per-subagent ledger.
ledger_dir="$HOME/.claude/post-format"
ledger="${ledger_dir}/${SESSION_ID}_${AGENT_ID}.txt"

mkdir -p "$ledger_dir"
printf '%s\n' "$FILE_PATH" >>"$ledger"

debug_log track-subagent-edits "appended to ledger=$ledger"

# Always allow — this hook only observes, never blocks.
exit 0
