#!/bin/bash
# build-no-success-before-commit.sh — PreToolUse Bash hook (no agent filter).
#
# HOOK-MANIFEST:
# event: PreToolUse
# matcher: Bash
# surface: user_global
# signal: none
# role: *
# harnesses: all
# GENERATED FROM shared/enforcement/registry.yaml — DO NOT EDIT
#
# Blocks any Bash command containing "BUILD_RESULT:" literal when the
# COMBOBULATE_BUILD_START_TS env var is set but no commit has been made
# since that timestamp.
#
# Context: ClaudeBuildRunnerImpl.build_stream_cmd/4 prepends
# "COMBOBULATE_BUILD_START_TS=$(date +%s) " to the shell command so it is
# available to the subprocess. If the orchestrator tries to signal
# BUILD_RESULT: before committing, this hook blocks it.
#
# Allow conditions:
#   - COMBOBULATE_BUILD_START_TS is unset or empty (not in a build context)
#   - At least one commit exists since COMBOBULATE_BUILD_START_TS

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
# shellcheck disable=SC1091
source "$(dirname "$0")/lib/gate-result.sh"
parse_input

debug_log build-no-success-before-commit "tool=$TOOL_NAME"

if [ "$TOOL_NAME" != "Bash" ]; then
    exit 0
fi

# Only inspect commands containing BUILD_RESULT: literal
if ! printf '%s' "$COMMAND" | grep -qF 'BUILD_RESULT:'; then
    exit 0
fi

# Not in a build context — allow
if [ -z "${COMBOBULATE_BUILD_START_TS:-}" ]; then
    debug_log build-no-success-before-commit "allow: COMBOBULATE_BUILD_START_TS unset"
    exit 0
fi

# Check for any commit strictly after build start (committer timestamp > start_ts).
# Uses git log -1 --format=%ct to get the most recent commit's epoch seconds.
# --since/@epoch is inclusive (same-second returns match), so we compare numerically.
project_dir="${CWD:-$PWD}"
latest_commit_ts=$(git -C "$project_dir" log -1 --format="%ct" 2>/dev/null)

if [ -z "$latest_commit_ts" ] || [ "$latest_commit_ts" -le "$COMBOBULATE_BUILD_START_TS" ]; then
    deny "BLOCKED by build-no-success-before-commit: BUILD_RESULT: found but no git commit has been made since build start (COMBOBULATE_BUILD_START_TS=$COMBOBULATE_BUILD_START_TS). Commit the generated code before signaling build success."
    exit 0
fi

# Require structured gate-result.json with verdict=clear in addition to commit check.
gate_verdict=$(gate_result_verdict "$project_dir")
if [ "$gate_verdict" != "clear" ]; then
    deny "BLOCKED by build-no-success-before-commit: BUILD_RESULT: found but gate-result.json does not show verdict=clear (current verdict: '${gate_verdict:-absent}'). A gate must run and produce a clear verdict before signaling build success."
    exit 0
fi

# Require a clean working tree — no uncommitted or untracked files.
dirty_files=$(git -C "$project_dir" status --porcelain 2>/dev/null)
if [ -n "$dirty_files" ]; then
    dirty_count=$(printf '%s\n' "$dirty_files" | grep -c .)
    dirty_list=$(printf '%s\n' "$dirty_files" | sed 's/^[^ ]* //' | tr '\n' ' ' | sed 's/ $//')
    deny "BLOCKED by build-no-success-before-commit: working tree not clean — ${dirty_count} file(s) uncommitted: ${dirty_list}. Commit all cycle output in one commit before signaling SHIPPED."
    exit 0
fi

debug_log build-no-success-before-commit "allow: commit at $latest_commit_ts found after build start $COMBOBULATE_BUILD_START_TS, gate verdict=clear, and working tree is clean"
exit 0
