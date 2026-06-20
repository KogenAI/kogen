#!/bin/bash
# clean-tree-before-ship.sh — PreToolUse Bash hook (no agent filter).
#
# HOOK-MANIFEST:
# event: PreToolUse
# matcher: Bash
# surface: user_global
# signal: none
# role: *
# harnesses: all
# rationale: Blocks the orchestrator ship-mv (mv codegen/pitches/ready/<slug>.md codegen/pitches/shipped/<slug>.md) when git status --porcelain is non-empty, preventing a pitch from being shipped while orphaned cycle output sits uncommitted. Fail-open outside a git repo.
# GENERATED FROM shared/enforcement/registry.yaml — DO NOT EDIT
#
# Blocks the orchestrator ship-mv
#   mv codegen/pitches/ready/<slug>.md codegen/pitches/shipped/<slug>.md
# when the working tree is not clean (git status --porcelain non-empty) —
# orphaned cycle output must be committed before the pitch is shipped.
#
# Allow conditions:
#   - command does not contain BOTH codegen/pitches/ready/ AND codegen/pitches/shipped/
#   - not in a git repo / git unavailable (fail-open)
#   - working tree clean

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
parse_input

debug_log clean-tree-before-ship "tool=$TOOL_NAME"

if [ "$TOOL_NAME" != "Bash" ]; then
    exit 0
fi

# Match only the ship mv: requires BOTH ready/ and shipped/ pitch paths.
if ! printf '%s' "$COMMAND" | grep -qF 'codegen/pitches/ready/'; then
    exit 0
fi
if ! printf '%s' "$COMMAND" | grep -qF 'codegen/pitches/shipped/'; then
    exit 0
fi

# Gate only an actual move verb (mv / git mv) — not mere co-mention of both
# pitch paths. Anchor mv at start-of-string or after a command separator
# (; && || | ( whitespace) so it is a command token, not a word substring.
# Absent -> allow (read-only / non-ship command).
if ! printf '%s' "$COMMAND" | grep -qE '(^|[;&|(]|[[:space:]])[[:space:]]*(git[[:space:]]+)?mv[[:space:]]'; then
    exit 0
fi

project_dir="${CWD:-$PWD}"

# Fail-open: not a git repo / git unavailable.
if ! git -C "$project_dir" rev-parse --show-toplevel >/dev/null 2>&1; then
    debug_log clean-tree-before-ship "allow: not a git repo"
    exit 0
fi

dirty_files=$(git -C "$project_dir" status --porcelain 2>/dev/null)
if [ -n "$dirty_files" ]; then
    dirty_count=$(printf '%s\n' "$dirty_files" | grep -c .)
    dirty_list=$(printf '%s\n' "$dirty_files" | sed 's/^[^ ]* //' | tr '\n' ' ' | sed 's/ $//')
    deny "BLOCKED by clean-tree-before-ship: working tree not clean — ${dirty_count} file(s) uncommitted: ${dirty_list}. Commit all cycle output before shipping the pitch (mv ready/ → shipped/)."
    exit 0
fi

debug_log clean-tree-before-ship "allow: working tree clean"
exit 0
