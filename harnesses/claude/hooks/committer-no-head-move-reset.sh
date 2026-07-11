#!/bin/bash
# committer-no-head-move-reset.sh — PreToolUse Bash hook scoped to committer.
#
# HOOK-MANIFEST:
# event: PreToolUse
# matcher: Bash
# surface: user_global
# signal: AGENT_TYPE
# role: committer
# harnesses: all
# rationale: Denies a HEAD-moving git reset (e.g. git reset HEAD~1, --hard/--soft/--keep/--merge, or a targeted commit-ish) from the committer agent, preventing a prior cycle's already-committed commit from being silently orphaned and folded into a new one.
# GENERATED FROM shared/enforcement/registry.yaml — DO NOT EDIT
#
# Denies any `git reset` invocation from the committer agent that would move
# HEAD to a different commit. A HEAD-moving reset (e.g. `git reset HEAD~1`)
# can silently drop an already-committed, possibly already-pushed commit from
# a prior cycle; a subsequent `git add -A && git commit` then folds that
# commit's diff into a new one, orphaning the original from the branch.
#
# Allow conditions:
#   - AGENT_TYPE != "committer" (defensive; registry already scopes this hook)
#   - Tool call is not Bash
#   - Command does not contain `git reset`
#   - `git reset` with no ref/mode that moves HEAD: bare `git reset`,
#     `git reset HEAD`, or any `-- <path>` path-scoped form
#   - COMMITTER_ALLOW_MULTI=1 is set (operator escape hatch; shared with the
#     sibling single-commit-per-cycle guard)
#
# Deny conditions:
#   - `--soft` / `--hard` / `--keep` / `--merge` mode flag present, OR
#   - A targeted commit-ish is present: HEAD~, HEAD^, @{, a 7-40 char hex SHA,
#     or a bare ref/branch/tag name that is not `HEAD` and not a `--` path arg
#
# Operator toggle (header comment only; do NOT add to .env.sample):
#   COMMITTER_ALLOW_MULTI=1  — skip this check entirely (emergency use only)

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
parse_input

debug_log committer-no-head-move-reset "tool=$TOOL_NAME agent=$AGENT_TYPE"

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

if ! printf '%s' "$COMMAND" | grep -qE '\bgit[[:space:]]+reset\b'; then
    exit 0
fi

if [ "${COMMITTER_ALLOW_MULTI:-}" = "1" ]; then
    debug_log committer-no-head-move-reset "allow: COMMITTER_ALLOW_MULTI=1"
    exit 0
fi

# Mode flags that always move HEAD regardless of the target.
if printf '%s' "$COMMAND" | grep -qE -- '--(soft|hard|keep|merge)\b'; then
    deny "BLOCKED by committer-no-head-move-reset: 'git reset' with a HEAD-moving mode flag (--soft/--hard/--keep/--merge) is forbidden. This can silently orphan a prior cycle's already-committed commit. To fix THIS cycle's commit use: git commit --amend. Emergency override: COMMITTER_ALLOW_MULTI=1"
    exit 0
fi

# Extract the reset invocation's arguments (everything after 'git reset' up
# to the next '&&', '||', ';', or '|', or end of string) to scope ref
# detection to this specific invocation, not the whole command line.
reset_args=$(printf '%s' "$COMMAND" | sed -E 's/^.*git[[:space:]]+reset//' | sed -E 's/[&|;].*$//')

# Strip a `-- <path...>` path-scoped suffix — anything after a bare `--` is a
# path, never a commit-ish, and must not trigger the ref-detection below.
reset_args_no_paths=$(printf '%s' "$reset_args" | sed -E 's/[[:space:]]--[[:space:]].*$//')

# Strip leading non-HEAD-moving option flags (-q/--quiet, -p/--patch, -N,
# -v/--verbose, etc.) so a leftover flag like `-q` does not survive into the
# ref-detection below and get misread as a target commit-ish.
# --soft/--hard/--keep/--merge are already denied earlier and are never seen here.
reset_args_no_flags=$(printf '%s' "$reset_args_no_paths" | sed -E 's/(^|[[:space:]])(-q|--quiet|-p|--patch|-N|--intent-to-add|-v|--verbose)([[:space:]]|$)/ /g')

# No target token left (bare `git reset`) — allowed, HEAD unmoved.
trimmed=$(printf '%s' "$reset_args_no_flags" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
if [ -z "$trimmed" ]; then
    debug_log committer-no-head-move-reset "allow: bare git reset (no target)"
    exit 0
fi

# Bare `HEAD` with nothing else is a no-op unstage — allowed.
if printf '%s' "$trimmed" | grep -qE '^HEAD$'; then
    debug_log committer-no-head-move-reset "allow: git reset HEAD (no-op unstage)"
    exit 0
fi

# Any remaining non-empty token set here is a target commit-ish that is not
# bare HEAD: HEAD~N, HEAD^, @{...}, a hex SHA, or a branch/tag/ref name.
# All of these move HEAD to a different commit — deny.
deny "BLOCKED by committer-no-head-move-reset: 'git reset' targeting a commit-ish other than bare HEAD is forbidden (detected: ${trimmed}). This can silently orphan a prior cycle's already-committed commit — a subsequent commit would fold that commit's diff into a new one, dropping it from the branch. Allowed forms: bare 'git reset', 'git reset HEAD', or 'git reset -- <path>' (path-scoped unstage). To fix THIS cycle's commit use: git commit --amend. Emergency override: COMMITTER_ALLOW_MULTI=1"
exit 0
