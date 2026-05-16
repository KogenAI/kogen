#!/bin/bash
# inspector-read-guard.sh — PreToolUse hook for Inspector
#
# HOOK-MANIFEST:
# event: PreToolUse
# matcher: Read
# surface: per_call_inspector
# signal: AGENT_TYPE
# role: inspector|inspector-phoenix|codex-inspector|cursor-inspector
#
# Blocks Read calls where the requested file_path is outside the Inspector's
# working directory ($CLAUDE_PROJECT_DIR, falling back to $PWD).

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
parse_input

require_inspector_agent_type

# Only gate Read calls.
if [ "$TOOL_NAME" != "Read" ]; then
    exit 0
fi

# Empty file_path — let the tool handle it.
if [ -z "$FILE_PATH" ]; then
    exit 0
fi

# Determine the Inspector's allowed working directory.
project_dir="${CLAUDE_PROJECT_DIR:-$PWD}"

# Normalise both paths via the lib helper (pure-bash realpath, handles
# non-existent paths via parent-walk).
real_project_dir=$(hooks_realpath "$project_dir")
real_file_path=$(hooks_realpath "$FILE_PATH")

# Add a trailing slash to the project dir so we can do a safe prefix check
# that won't match /home/alice-extra when project dir is /home/alice.
project_prefix="${real_project_dir%/}/"

# Allow access if the resolved file path starts with the project prefix
# OR equals the project dir exactly.
if [ "$real_file_path" = "$real_project_dir" ] ||
    case "$real_file_path" in "${project_prefix}"*) true ;; *) false ;; esac then
    exit 0
fi

deny "BLOCKED by inspector-read-guard: Read path $FILE_PATH is outside working dir $project_dir"
exit 0
