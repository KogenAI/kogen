#!/bin/bash
# inspector-read-guard.sh — PreToolUse hook for Inspector
#
# Blocks Read calls where the requested file_path is outside the Inspector's
# working directory ($CLAUDE_PROJECT_DIR, falling back to $PWD).
#
# Path containment check uses python3 os.path.realpath on both sides so:
#   - symlinks are resolved to their real targets before comparison
#   - ".." segments and trailing slashes are normalised
#   - non-existent paths are handled without error (unlike macOS realpath)
#
# Exit codes:
#   0 — allow the tool call
#   2 — block the tool call (Claude Code PreToolUse convention)

set -euo pipefail

input=$(cat)

tool_name=$(printf '%s' "$input" | jq -r '.tool_name // ""')

# Only gate Read calls.
if [ "$tool_name" != "Read" ]; then
    exit 0
fi

file_path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // ""')

# Empty file_path — let the tool handle it.
if [ -z "$file_path" ]; then
    exit 0
fi

# Determine the Inspector's allowed working directory.
project_dir="${CLAUDE_PROJECT_DIR:-$PWD}"

# Normalise both paths: resolve symlinks, strip "..", normalise slashes.
# python3 os.path.realpath handles non-existent paths without error.
real_project_dir=$(python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$project_dir")
real_file_path=$(python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$file_path")

# Add a trailing slash to the project dir so we can do a safe prefix check
# that won't match /home/alice-extra when project dir is /home/alice.
project_prefix="${real_project_dir%/}/"

# Allow access if the resolved file path starts with the project prefix
# OR equals the project dir exactly.
if [ "$real_file_path" = "$real_project_dir" ] ||
    case "$real_file_path" in "${project_prefix}"*) true ;; *) false ;; esac then
    exit 0
fi

printf 'BLOCKED by inspector-read-guard: Read path %s is outside working dir %s\n' \
    "$file_path" "$project_dir" >&2
exit 2
