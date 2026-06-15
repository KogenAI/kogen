#!/usr/bin/env bash
# curator-learning-committed.sh — PreToolUse Bash hook (no agent filter).
#
# HOOK-MANIFEST:
# event: PreToolUse
# matcher: Bash
# surface: user_global
# signal: none
# role: *
# harnesses: all
# rationale: Blocks BUILD_RESULT: success when a context-curator-recorded `Files edited:` tracked file is missing from the cycle commit (HEAD), preventing silent loss of curator learnings dropped at the 40,960-byte context cap.
# GENERATED FROM shared/enforcement/registry.yaml — DO NOT EDIT
#
# Allow conditions:
#   - Not a BUILD_RESULT: command
#   - CODEGEN_BUILD_START_TS unset or empty (not in a build context)
#   - No session log resolvable (fail-open)
#   - Section absent from session log (fail-open)
#   - Files edited: none
#   - Files edited: marker absent or malformed (fail-open)
#   - All recorded files in HEAD
#   - Recorded file is gitignored (dropped — session log paths etc.)
#
# Deny conditions:
#   - A curator-recorded file is NOT in HEAD (curator learning lost)

set -euo pipefail

source "$(dirname "$0")/lib/hooks-lib.sh"
parse_input

build_start_ts="${CODEGEN_BUILD_START_TS:-}"

debug_log curator-learning-committed "tool=$TOOL_NAME"

if [ "$TOOL_NAME" != "Bash" ]; then
    exit 0
fi

# Only inspect commands containing BUILD_RESULT: literal
if ! printf '%s' "$COMMAND" | grep -qF 'BUILD_RESULT:'; then
    exit 0
fi

# Not in a build context — allow
if [ -z "$build_start_ts" ]; then
    debug_log curator-learning-committed "allow: CODEGEN_BUILD_START_TS unset"
    exit 0
fi

project_dir="${CWD:-$PWD}"

# Resolve session log
session_log=$(session_log_from_transcript)

# Fallback: newest .md in project codegen/logging/ if transcript scan empty
if [ -z "$session_log" ]; then
    session_log=$(ls -t "$project_dir/codegen/logging"/*.md 2>/dev/null | head -1 || true)
fi

if [ -z "$session_log" ] || [ ! -r "$session_log" ]; then
    debug_log curator-learning-committed "allow: session log not resolvable — fail-open"
    exit 0
fi

debug_log curator-learning-committed "session_log=$session_log"

# Extract the curator section body: from "## context-curator Section" to next "^## "
curator_section=$(awk '
    /^## context-curator Section/ { in_section=1; next }
    in_section && /^## / { in_section=0 }
    in_section { print }
' "$session_log")

if [ -z "$curator_section" ]; then
    debug_log curator-learning-committed "allow: no context-curator Section found"
    exit 0
fi

# Extract the "Files edited:" line from the section
files_line=$(printf '%s\n' "$curator_section" | grep -E '^Files edited:' | tail -n 1 || true)

if [ -z "$files_line" ]; then
    debug_log curator-learning-committed "allow: Files edited: marker absent — fail-open"
    exit 0
fi

# Strip the "Files edited: " prefix
recorded_raw="${files_line#Files edited:}"
recorded_raw="${recorded_raw# }" # strip leading space

if [ -z "$recorded_raw" ] || [ "$recorded_raw" = "none" ]; then
    debug_log curator-learning-committed "allow: Files edited: none or empty"
    exit 0
fi

# Split space-separated paths into array
read -r -a recorded_paths <<<"$recorded_raw"

# Get committed files in HEAD (name-only, no format prefix)
committed_files=$(git -C "$project_dir" show --name-only --format= HEAD 2>/dev/null || true)

# Check each recorded path
for fpath in "${recorded_paths[@]}"; do
    # Skip gitignored files (e.g. session log path under codegen/)
    if git -C "$project_dir" check-ignore -q "$fpath" 2>/dev/null; then
        debug_log curator-learning-committed "skip gitignored: $fpath"
        continue
    fi

    # Normalize: strip leading "./" if present
    normalized="${fpath#./}"

    if ! printf '%s\n' "$committed_files" | grep -qxF "$normalized"; then
        deny "BLOCKED by curator-learning-committed: curator recorded 'Files edited: $fpath' but that file is missing from HEAD.

The curator's learning was not committed. Possible causes:
  1. The context/*.md file exceeded the 40,960-byte cap and was reverted by context-file-size-gate — compress a stale bullet, relocate a verbose example, or split to a new context file, then re-drive the curator.
  2. The file was not staged before the commit — restage the curator's edits (git add $fpath) and amend the commit.

Re-drive the curator to fix, then recommit before signaling BUILD_RESULT: success."
        exit 0
    fi
done

debug_log curator-learning-committed "allow: all curator-recorded files found in HEAD"
exit 0
