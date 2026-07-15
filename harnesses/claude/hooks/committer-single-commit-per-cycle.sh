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
# same build cycle. Counts commits reachable from HEAD but not from
# CODEGEN_CYCLE_BASE_SHA (the SHA captured ONCE at cycle start, before any
# role ran — identical across every role's env, unlike the per-role
# CODEGEN_BUILD_START_TS timestamp). If ≥1 such commit exists and the
# incoming command is not --amend, the command is denied. This also catches
# a commit made by an EARLIER role in the same cycle (e.g. an evaded
# pre-commit-guard bypass) — the per-role timestamp window missed this.
#
# Allow conditions:
#   - AGENT_TYPE != "committer" (defensive; registry already scopes this hook)
#   - Tool call does not contain git commit
#   - --amend is present in the command
#   - COMMITTER_ALLOW_MULTI=1 is set (operator escape hatch)
#   - CODEGEN_CYCLE_BASE_SHA unset or empty (not a build cycle / unborn HEAD)
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

if ! printf '%s' "$COMMAND" | grep -qE '\bgit[[:space:]]+commit([[:space:];&|]|$)'; then
    exit 0
fi

project_dir="${CLAUDE_PROJECT_DIR:-${CWD:-$PWD}}"

base_sha="${CODEGEN_CYCLE_BASE_SHA:-}"

if printf '%s' "$COMMAND" | grep -qE -- '--amend'; then
    if [ -n "$base_sha" ]; then
        cycle_commit_count="$(git -C "$project_dir" rev-list --count "$base_sha"..HEAD 2>/dev/null || true)"
        if [ -n "$cycle_commit_count" ] && [ "$cycle_commit_count" -eq 0 ] 2>/dev/null; then
            deny "BLOCKED by committer-single-commit-per-cycle: --amend has nothing to amend within this build cycle (HEAD == cycle base ${base_sha}). No commit from this cycle exists yet — that would rewrite a commit from BEFORE this build cycle, which is immutable to this one. To allow (emergency only): set COMMITTER_ALLOW_MULTI=1"
            exit 0
        fi
    fi
    debug_log committer-single-commit-per-cycle "allow: --amend present (a cycle commit exists or base sha unset)"
    exit 0
fi

if [ "${COMMITTER_ALLOW_MULTI:-}" = "1" ]; then
    debug_log committer-single-commit-per-cycle "allow: COMMITTER_ALLOW_MULTI=1"
    exit 0
fi

if [ -z "$base_sha" ]; then
    debug_log committer-single-commit-per-cycle "allow: CODEGEN_CYCLE_BASE_SHA unset"
    exit 0
fi

session_count="$(git -C "$project_dir" rev-list --count "$base_sha"..HEAD 2>/dev/null || true)"

if [ -z "$session_count" ] || [ "$session_count" -eq 0 ] 2>/dev/null; then
    debug_log committer-single-commit-per-cycle "allow: no session commits yet"
    exit 0
fi

deny "BLOCKED by committer-single-commit-per-cycle: a commit was already made in this build cycle (${session_count} session commit(s) found since cycle base ${base_sha}).
Only one commit per build cycle is allowed.
To amend the existing commit use: git commit --amend
To allow multiple commits (emergency only): set COMMITTER_ALLOW_MULTI=1"

exit 0
