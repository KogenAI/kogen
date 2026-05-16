#!/bin/bash
# codex-inspector-read-guard.sh — PreToolUse hook for Codex Inspector
#
# HOOK-MANIFEST:
# event: PreToolUse
# matcher: read_file
# surface: per_call_inspector
# signal: CODEX_ROLE
# role: codex-inspector
#
# Blocks read_file calls where the requested path is outside the Inspector's
# working directory ($CODEX_PROJECT_DIR, falling back to $PWD).
#
# Codex 0.51+ exposes a separate `read_file` tool; this guard mirrors the
# Claude inspector-read-guard.sh semantics for that surface. The Codex bash
# guard handles cat/head/tail-style read containment for the shell surface.

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
parse_input

# Only active when CODEX_ROLE=inspector.
[ "${CODEX_ROLE:-}" = "inspector" ] || exit 0

# Only gate read_file calls.
if [ "$TOOL_NAME" != "read_file" ]; then
    exit 0
fi

# Empty file_path — let the tool handle it.
if [ -z "$FILE_PATH" ]; then
    exit 0
fi

# Determine the Inspector's allowed working directory.
project_dir="${CODEX_PROJECT_DIR:-$PWD}"

real_project_dir=$(hooks_realpath "$project_dir")
real_file_path=$(hooks_realpath "$FILE_PATH")

project_prefix="${real_project_dir%/}/"

if [ "$real_file_path" = "$real_project_dir" ] ||
    case "$real_file_path" in "${project_prefix}"*) true ;; *) false ;; esac then
    exit 0
fi

deny "BLOCKED by codex-inspector-read-guard: read_file path $FILE_PATH is outside working dir $project_dir"
exit 0
