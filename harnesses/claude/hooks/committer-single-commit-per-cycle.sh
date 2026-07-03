#!/bin/bash
# committer-single-commit-per-cycle.sh — PreToolUse Bash hook scoped to committer.
#
# HOOK-MANIFEST:
# event: PreToolUse
# matcher: Bash
# surface: user_global
# signal: AGENT_TYPE
# role: committer
# harnesses: all
# rationale: Denies a second non-amend git commit from the committer agent within the same build cycle, enforcing one commit per cycle and preventing accidental double-commits.
# GENERATED FROM shared/enforcement/registry.yaml — DO NOT EDIT
#
# Denies a second non-amend git commit from the committer agent within the
# same build cycle. Counts commits made after CODEGEN_BUILD_START_TS; if ≥1
# exists and the incoming command is not --amend, the command is denied.
#
# Allow conditions:
#   - AGENT_TYPE != "committer" (defensive; registry already scopes this hook)
#   - Tool call does not contain git commit
#   - --amend is present in the command
#   - COMMITTER_ALLOW_MULTI=1 is set (operator escape hatch)
#   - CODEGEN_BUILD_START_TS unset or empty (not a build cycle)
#   - No session commits yet (first commit of the cycle)
#
# Operator toggle (header comment only; do NOT add to .env.sample):
#   COMMITTER_ALLOW_MULTI=1  — skip this check entirely (emergency use only)

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
parse_input

debug_log committer-single-commit-per-cycle "tool=$TOOL_NAME agent=$AGENT_TYPE"

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

if ! printf '%s' "$COMMAND" | grep -qE '\bgit[[:space:]]+commit\b'; then
    exit 0
fi

project_dir="${CLAUDE_PROJECT_DIR:-${CWD:-$PWD}}"

if printf '%s' "$COMMAND" | grep -qE -- '--amend'; then
    build_start_ts="${CODEGEN_BUILD_START_TS:-}"
    if [ -n "$build_start_ts" ]; then
        head_ct="$(git -C "$project_dir" log -1 --format=%ct 2>/dev/null || true)"
        if [ -n "$head_ct" ] && [ "$head_ct" -lt "$build_start_ts" ] 2>/dev/null; then
            deny "BLOCKED by committer-single-commit-per-cycle: --amend would rewrite a commit from BEFORE this build cycle (HEAD commit time ${head_ct} < cycle start ${build_start_ts}). That commit belongs to a prior cycle and is immutable to this one. To allow (emergency only): set COMMITTER_ALLOW_MULTI=1"
            exit 0
        fi
    fi
    debug_log committer-single-commit-per-cycle "allow: --amend present (HEAD time ok or start ts unset)"
    exit 0
fi

if [ "${COMMITTER_ALLOW_MULTI:-}" = "1" ]; then
    debug_log committer-single-commit-per-cycle "allow: COMMITTER_ALLOW_MULTI=1"
    exit 0
fi

build_start_ts="${CODEGEN_BUILD_START_TS:-}"
if [ -z "$build_start_ts" ]; then
    debug_log committer-single-commit-per-cycle "allow: CODEGEN_BUILD_START_TS unset"
    exit 0
fi

session_commits=$(git -C "$project_dir" log --format="%H %ct" 2>/dev/null |
    while IFS=' ' read -r sha ct; do
        if [ "$ct" -gt "$build_start_ts" ] 2>/dev/null; then
            printf '%s\n' "$sha"
        fi
    done)

if [ -z "$session_commits" ]; then
    debug_log committer-single-commit-per-cycle "allow: no session commits yet"
    exit 0
fi

session_count=$(printf '%s\n' "$session_commits" | grep -c '.')
deny "BLOCKED by committer-single-commit-per-cycle: a commit was already made in this build cycle (${session_count} session commit(s) found).
Only one commit per build cycle is allowed.
To amend the existing commit use: git commit --amend
To allow multiple commits (emergency only): set COMMITTER_ALLOW_MULTI=1"

exit 0
