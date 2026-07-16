#!/bin/bash
# pre-commit-guard.sh — PreToolUse hook for every agent except "committer"
#
# HOOK-MANIFEST:
# event: PreToolUse
# matcher: Bash
# surface: user_global
# signal: AGENT_TYPE
# role: *
# harnesses: all
# registration only (hand-authored body) — the registry entry for this hook
# is `kind: registration`, which emits ONLY the settings.json wiring; the
# check logic below is NOT generated and is safe to hand-edit.
#
# Blocks state-modifying git commands (commit, rebase, push --force,
# reset --hard, cherry-pick, revert, merge) when the active agent is
# anything other than "committer". The orchestrator itself (agent_type
# is "") is also blocked — per CLAUDE.md only the committer may touch
# history.
#
# Ops mode (CLAUDE_ROLE=ops / PI_ROLE=ops) and babysit mode (CLAUDE_ROLE=babysit
# / PI_ROLE=babysit) scope the gate to destructive git verbs ONLY — non-git
# Bash, read-only git (status/diff/log/show), and a plain `git push` pass
# straight through for interactive ops on live boxes or the drain supervisor's
# post-ship push. Destructive git ALSO requires CODEGEN_OPS_GIT_UNLOCK=1 — a
# two-signal gate. Role alone no longer unlocks destructive git under the
# fail-closed-everywhere ruling; the operator must explicitly confirm intent
# via a second, harness-only toggle (NOT an app runtime var — do not add to
# .env.sample/.env.prod.sample).
set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
source "$(dirname "$0")/_role.sh"
parse_input

debug_log pre-commit-guard "tool=$TOOL_NAME agent=$AGENT_TYPE cmd=$COMMAND"

# Only guard Bash — git ops go through Bash exclusively.
if [ "$TOOL_NAME" != "Bash" ]; then
    exit 0
fi

# ops/babysit mode: scope the gate to destructive git verbs only. Non-git Bash
# and read-only git (status/diff/log/show/blame/ls-files) — and a plain `git
# push` — pass straight through; the gate must NOT return a verdict for all
# Bash before checking whether the command is even a destructive git
# invocation. babysit needs this same posture: it plain-pushes after every
# verified ship but never force-pushes or mutates history.
_role=$(resolve_role)
if [ "$_role" = "ops" ] || [ "$_role" = "babysit" ]; then
    # Fail-closed subject transform (see strip_quoted() in hooks-lib.sh):
    # a destructive git verb inside a quoted remote payload or string
    # argument is not a real local invocation; strip before matching.
    # Also normalize interposed git global options (git -C <dir> commit)
    # so they cannot evade the verb match — see strip_git_global_opts().
    _ops_cmd_unquoted=$(strip_git_global_opts "$(strip_quoted "$COMMAND")")
    _ops_is_destructive=0
    if printf '%s' "$_ops_cmd_unquoted" | grep -qE '\bgit[[:space:]]+(add|rm|mv|stash|commit|rebase|cherry-pick|revert|merge|restore|checkout|switch)\b|\bgit[[:space:]]+reset\b.*--(hard|merge|keep)\b|\bgit[[:space:]]+push\b.*(--force(-with-lease)?|[[:space:]]-f([[:space:]]|$))'; then
        _ops_is_destructive=1
    fi
    if printf '%s' "$_ops_cmd_unquoted" | grep -qE '\bgit[[:space:]]+clean\b' && ! printf '%s' "$_ops_cmd_unquoted" | grep -qE '\bgit[[:space:]]+clean\b.*(-n\b|--dry-run\b)'; then
        _ops_is_destructive=1
    fi
    if [ "$_ops_is_destructive" = 1 ]; then
        [ "${CODEGEN_OPS_GIT_UNLOCK:-}" = "1" ] && exit 0
        deny "BLOCKED by pre-commit-guard: ops role alone no longer unlocks destructive git. Set CODEGEN_OPS_GIT_UNLOCK=1 in the environment ALSO to confirm intent (two-signal gate)."
        exit 0
    fi
    exit 0
fi

# Committer is the sole allowed writer of history.
if [ "$AGENT_TYPE" = "committer" ]; then
    exit 0
fi

# codegen-log carve-out (mirrors session-log-writer-only.sh): every role's
# session-log section body is written via
# `printf '%s' "$body" | codegen-log section --body @-`, so the piped body is
# arbitrary role-authored prose that may legitimately contain git verb tokens
# (e.g. describing a commit or a git operation the role observed). Exit-allow
# BEFORE the git-verb scans below so codegen-log invocations are never denied
# by prose in their own piped body. The body is DATA to codegen-log, never
# executed — codegen-log only writes logs. Bare history-mutating git commands
# (not routed through codegen-log) remain denied below.
if printf '%s' "$COMMAND" | grep -qE '(^|[[:space:]/])codegen-log\b'; then
    exit 0
fi

# Fail-closed subject transform: strip single/double-quoted spans so a
# forbidden git verb sitting inside a quoted remote-exec payload (ssh host
# "git stash") or a quoted string argument (grep -n 'git stash' file.sh) does
# not trigger this guard. A real, unquoted, local git-verb invocation still
# matches and is still denied. See strip_quoted() in hooks-lib.sh. Also
# normalize interposed git global options (git -C <dir> commit, git
# --git-dir=<x> add, …) so they cannot evade the verb match below — see
# strip_git_global_opts() in hooks-lib.sh.
_cmd_unquoted=$(strip_git_global_opts "$(strip_quoted "$COMMAND")")

# State-modifying git subcommands. Notably NOT blocked: status, diff,
# log, show, blame, ls-files — these are routinely used for inspection by
# every subagent.
if printf '%s' "$_cmd_unquoted" | grep -qE '\bgit[[:space:]]+add\b'; then
    deny "BLOCKED by pre-commit-guard: git add is forbidden for agent \"$AGENT_TYPE\" — committer owns all git staging. Do not stage; leave changes in the working tree, the loop's committer step runs after you — finish your remaining in-role work and stop."
    exit 0
fi

if printf '%s' "$_cmd_unquoted" | grep -qE '\bgit[[:space:]]+rm\b'; then
    deny "BLOCKED by pre-commit-guard: git rm is forbidden for agent \"$AGENT_TYPE\" — committer owns all git staging. Do not stage; leave changes in the working tree, the loop's committer step runs after you — finish your remaining in-role work and stop."
    exit 0
fi

if printf '%s' "$_cmd_unquoted" | grep -qE '\bgit[[:space:]]+mv\b'; then
    deny "BLOCKED by pre-commit-guard: git mv is forbidden for agent \"$AGENT_TYPE\" — committer owns all git staging. Do not stage; leave changes in the working tree, the loop's committer step runs after you — finish your remaining in-role work and stop."
    exit 0
fi

if printf '%s' "$_cmd_unquoted" | grep -qE '\bgit[[:space:]]+restore\b'; then
    deny "BLOCKED by pre-commit-guard: git restore is forbidden for agent \"$AGENT_TYPE\" — this can DISCARD your own or another role's uncommitted working-tree edits (with or without --staged). To READ committed content use \`git show HEAD:<path>\`; to change a file you own use Edit/Write; a revert belongs to the committer. Do not restore; leave changes in the working tree, the loop's committer step runs after you — finish your remaining in-role work and stop."
    exit 0
fi

if printf '%s' "$_cmd_unquoted" | grep -qE '\bgit[[:space:]]+(checkout|switch)\b'; then
    deny "BLOCKED by pre-commit-guard: git checkout/switch is forbidden for agent \"$AGENT_TYPE\" — checkout of a path can DISCARD uncommitted working-tree edits (yours or another role's), and branch switches belong to the committer. To READ committed content use \`git show HEAD:<path>\`; to change a file you own use Edit/Write. Do not checkout/switch; leave the working tree as-is, the loop's committer step runs after you — finish your remaining in-role work and stop."
    exit 0
fi

if printf '%s' "$_cmd_unquoted" | grep -qE '\bgit[[:space:]]+clean\b' && ! printf '%s' "$_cmd_unquoted" | grep -qE '\bgit[[:space:]]+clean\b.*(-n\b|--dry-run\b)'; then
    deny "BLOCKED by pre-commit-guard: git clean (without -n/--dry-run) is forbidden for agent \"$AGENT_TYPE\" — it PERMANENTLY DELETES untracked files, including another role's uncommitted new files. Use \`git clean -n\` to preview only, or ask the committer. Do not clean; leave the working tree as-is, the loop's committer step runs after you — finish your remaining in-role work and stop."
    exit 0
fi

if printf '%s' "$_cmd_unquoted" | grep -qE '\bgit[[:space:]]+commit([[:space:];&|]|$)'; then
    deny "BLOCKED by pre-commit-guard: git commit forbidden for agent \"$AGENT_TYPE\" — committer owns commit creation (see CLAUDE.md \"NEVER Commit Directly\"). Do not commit; leave changes uncommitted in the working tree, the loop's committer step runs after you — finish your remaining in-role work and stop."
    exit 0
fi

if printf '%s' "$_cmd_unquoted" | grep -qE '\bgit[[:space:]]+rebase\b'; then
    deny "BLOCKED by pre-commit-guard: git rebase forbidden for agent \"$AGENT_TYPE\" — committer owns history. Do not rebase; leave the branch as-is, the loop's committer step runs after you — finish your remaining in-role work and stop."
    exit 0
fi

if printf '%s' "$_cmd_unquoted" | grep -qE '\bgit[[:space:]]+cherry-pick\b'; then
    deny "BLOCKED by pre-commit-guard: git cherry-pick forbidden for agent \"$AGENT_TYPE\" — committer owns history. Do not cherry-pick; leave the branch as-is, the loop's committer step runs after you — finish your remaining in-role work and stop."
    exit 0
fi

if printf '%s' "$_cmd_unquoted" | grep -qE '\bgit[[:space:]]+revert\b'; then
    deny "BLOCKED by pre-commit-guard: git revert forbidden for agent \"$AGENT_TYPE\" — committer owns history. Do not revert; leave the branch as-is, the loop's committer step runs after you — finish your remaining in-role work and stop."
    exit 0
fi

if printf '%s' "$_cmd_unquoted" | grep -qE '\bgit[[:space:]]+merge\b'; then
    deny "BLOCKED by pre-commit-guard: git merge forbidden for agent \"$AGENT_TYPE\" — committer owns history. Do not merge; leave the branch as-is, the loop's committer step runs after you — finish your remaining in-role work and stop."
    exit 0
fi

# git reset --hard / --merge / --keep (all destructive to the working tree).
if printf '%s' "$_cmd_unquoted" | grep -qE '\bgit[[:space:]]+reset\b.*--(hard|merge|keep)\b'; then
    deny "BLOCKED by pre-commit-guard: git reset --hard/--merge/--keep forbidden for agent \"$AGENT_TYPE\" — destructive, committer owns history. Do not reset; leave the working tree as-is, the loop's committer step runs after you — finish your remaining in-role work and stop."
    exit 0
fi

# Soft/mixed reset is only allowed when it stays within this cycle's own HEAD.
if printf '%s' "$_cmd_unquoted" | grep -qE '\bgit[[:space:]]+reset\b' && ! printf '%s' "$_cmd_unquoted" | grep -qE '\bgit[[:space:]]+reset\b.*--(hard|merge|keep)\b'; then
    build_start_ts="${CODEGEN_BUILD_START_TS:-}"
    if [ -n "$build_start_ts" ]; then
        project_dir="${CLAUDE_PROJECT_DIR:-${CWD:-$PWD}}"
        head_ct="$(git -C "$project_dir" log -1 --format=%ct 2>/dev/null || true)"
        if [ -n "$head_ct" ] && [ "$head_ct" -lt "$build_start_ts" ] 2>/dev/null; then
            deny "BLOCKED by pre-commit-guard: git reset would rewrite a commit from BEFORE this build cycle (HEAD commit time ${head_ct} < cycle start ${build_start_ts}). That commit belongs to a prior cycle and is immutable to this one. To allow (emergency only): set COMMITTER_ALLOW_MULTI=1"
            exit 0
        fi
    fi
fi

# git push --force / --force-with-lease / -f
if printf '%s' "$_cmd_unquoted" | grep -qE '\bgit[[:space:]]+push\b.*(--force(-with-lease)?|[[:space:]]-f([[:space:]]|$))'; then
    deny "BLOCKED by pre-commit-guard: git push --force forbidden for agent \"$AGENT_TYPE\" — committer owns push discipline. Do not force-push; leave the branch as-is, the loop's committer step runs after you — finish your remaining in-role work and stop."
    exit 0
fi

exit 0
