#!/bin/bash
# committer-no-revert-prior-commit.sh — PreToolUse Bash hook scoped to committer.
#
# HOOK-MANIFEST:
# event: PreToolUse
# matcher: Bash
# surface: user_global
# signal: AGENT_TYPE
# role: committer
# harnesses: all
# rationale: Blocks git commit when staged content would byte-identically match a file state that a prior session commit already superseded, preventing silent backward rolls within the same build session.
# GENERATED FROM shared/enforcement/registry.yaml — DO NOT EDIT
#
# Blocks git commit when staged content would byte-identically match a file
# state that a prior session commit already superseded, preventing silent
# backward rolls within the same build session.
#
# A "backward roll" on file F means:
#   - Session commit C (committed after CODEGEN_BUILD_START_TS) changed F
#   - The currently staged version of F is byte-identical to F's content at
#     C's parent (the state *before* C was made)
#
# Allow conditions:
#   - AGENT_TYPE != "committer" (defensive; registry already scopes this hook)
#   - Tool call does not contain `git commit`
#   - COMMITTER_ALLOW_REVERT=1 is set (documented operator escape hatch)
#   - CODEGEN_BUILD_START_TS unset or empty (not in a build context)
#   - No commits exist in the session yet (first commit — nothing to protect)
#   - No staged file matches a superseded prior state
#
# Operator toggle (header comment only; do NOT add to .env.sample):
#   COMMITTER_ALLOW_REVERT=1  — skip this check entirely (emergency use only)

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
parse_input

debug_log committer-no-revert-prior-commit "tool=$TOOL_NAME agent=$AGENT_TYPE"

# Only gate the committer (defensive; registry already enforces this)
if [ "$AGENT_TYPE" != "committer" ]; then
    exit 0
fi

if [ "$TOOL_NAME" != "Bash" ]; then
    exit 0
fi

# A codegen-log write narrates gated phrases in its heredoc body; it is never
# the gated action itself. Bypass before any phrase match or counter increment.
if is_codegen_log_write; then
    exit 0
fi

# Only inspect git commit commands
if ! printf '%s' "$COMMAND" | grep -qE '\bgit[[:space:]]+commit\b'; then
    exit 0
fi

# Operator escape hatch
if [ "${COMMITTER_ALLOW_REVERT:-}" = "1" ]; then
    debug_log committer-no-revert-prior-commit "allow: COMMITTER_ALLOW_REVERT=1"
    exit 0
fi

# Not in a build context — allow
build_start_ts="${CODEGEN_BUILD_START_TS:-}"
if [ -z "$build_start_ts" ]; then
    debug_log committer-no-revert-prior-commit "allow: CODEGEN_BUILD_START_TS unset"
    exit 0
fi

project_dir="${CLAUDE_PROJECT_DIR:-${CWD:-$PWD}}"

# Collect session commits: SHAs committed after build start timestamp
session_commits=$(git -C "$project_dir" log --format="%H %ct" 2>/dev/null |
    while IFS=' ' read -r sha ct; do
        if [ "$ct" -gt "$build_start_ts" ] 2>/dev/null; then
            printf '%s\n' "$sha"
        fi
    done)

# No session commits yet — first commit of session, nothing to protect against
if [ -z "$session_commits" ]; then
    debug_log committer-no-revert-prior-commit "allow: no session commits yet"
    exit 0
fi

# Get staged file list
staged_files=$(git -C "$project_dir" diff --cached --name-only 2>/dev/null)

if [ -z "$staged_files" ]; then
    debug_log committer-no-revert-prior-commit "allow: no staged files"
    exit 0
fi

# For each staged file, compare its staged content against the pre-session-commit
# parent state. If they match byte-for-byte and the session commit changed that
# file, it is a backward roll.
backward_roll_files=""

TMP_STAGED=$(mktemp)
TMP_PARENT=$(mktemp)
trap 'rm -f "$TMP_STAGED" "$TMP_PARENT"' EXIT

while IFS= read -r staged_file; do
    [ -z "$staged_file" ] && continue

    # Get the staged (index) content — use process substitution-safe temp file
    if ! git -C "$project_dir" show ":${staged_file}" >"$TMP_STAGED" 2>/dev/null; then
        # File not in index (e.g. deleted) — skip
        continue
    fi

    # Check against each session commit's parent state
    while IFS= read -r session_sha; do
        [ -z "$session_sha" ] && continue

        # Check if this session commit touched the file
        changed_in_commit=$(git -C "$project_dir" diff --name-only "${session_sha}^" "${session_sha}" -- "${staged_file}" 2>/dev/null)
        if [ -z "$changed_in_commit" ]; then
            # This session commit did not change the file — skip
            continue
        fi

        # Get parent state of the file
        parent_sha="${session_sha}^"
        if ! git -C "$project_dir" show "${parent_sha}:${staged_file}" >"$TMP_PARENT" 2>/dev/null; then
            # File did not exist before this commit (new file) — no ancestor state to revert to
            continue
        fi

        # Compare staged vs parent byte-for-byte
        if cmp -s "$TMP_STAGED" "$TMP_PARENT"; then
            if [ -z "$backward_roll_files" ]; then
                backward_roll_files="${staged_file} (reverts ${session_sha})"
            else
                backward_roll_files="${backward_roll_files}
  ${staged_file} (reverts ${session_sha})"
            fi
            break
        fi
    done <<EOF
$session_commits
EOF

done <<EOF
$staged_files
EOF

if [ -n "$backward_roll_files" ]; then
    deny "BLOCKED by committer-no-revert-prior-commit: staged content silently reverts work from a prior session commit.
Files that would roll back:
  ${backward_roll_files}
This is a backward roll — the staged version is byte-identical to the state BEFORE a session commit advanced it.
If this is intentional, set COMMITTER_ALLOW_REVERT=1 and retry."
    exit 0
fi

debug_log committer-no-revert-prior-commit "allow: no backward rolls detected"
exit 0
