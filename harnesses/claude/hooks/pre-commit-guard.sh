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
# GENERATED FROM shared/enforcement/registry.yaml — DO NOT EDIT
#
# Blocks state-modifying git commands (commit, rebase, push --force,
# reset --hard, cherry-pick, revert, merge) when the active agent is
# anything other than "committer". The orchestrator itself (agent_type
# is "") is also blocked — per CLAUDE.md only the committer may touch
# history.
#
# Ops mode (CLAUDE_ROLE=ops / PI_ROLE=ops) bypasses ONLY when the operator
# ALSO sets CODEGEN_OPS_GIT_UNLOCK=1 — a two-signal gate. Role alone no
# longer unlocks destructive git under the fail-closed-everywhere ruling;
# the operator must explicitly confirm intent via a second, harness-only
# toggle (NOT an app runtime var — do not add to .env.sample/.env.prod.sample).
set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
source "$(dirname "$0")/_role.sh"
parse_input

debug_log pre-commit-guard "tool=$TOOL_NAME agent=$AGENT_TYPE cmd=$COMMAND"

# ops mode bypasses: full git surface for interactive ops on live boxes,
# but ONLY with CODEGEN_OPS_GIT_UNLOCK=1 as a second confirming signal.
_role=$(resolve_role)
if [ "$_role" = "ops" ]; then
    if [ "${CODEGEN_OPS_GIT_UNLOCK:-}" = "1" ]; then
        exit 0
    fi
    deny "BLOCKED by pre-commit-guard: ops role alone no longer unlocks destructive git. Set CODEGEN_OPS_GIT_UNLOCK=1 in the environment ALSO to confirm intent (two-signal gate)."
    exit 0
fi

# Only guard Bash — git ops go through Bash exclusively.
if [ "$TOOL_NAME" != "Bash" ]; then
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

# State-modifying git subcommands. Notably NOT blocked: status, diff,
# log, show, blame, ls-files — these are routinely used for inspection by
# every subagent.
if printf '%s' "$COMMAND" | grep -qE '\bgit[[:space:]]+add\b'; then
    deny "BLOCKED by pre-commit-guard: git add is forbidden for agent \"$AGENT_TYPE\" — committer owns all git staging (delegate to committer)"
    exit 0
fi

if printf '%s' "$COMMAND" | grep -qE '\bgit[[:space:]]+rm\b'; then
    deny "BLOCKED by pre-commit-guard: git rm is forbidden for agent \"$AGENT_TYPE\" — committer owns all git staging (delegate to committer)"
    exit 0
fi

if printf '%s' "$COMMAND" | grep -qE '\bgit[[:space:]]+mv\b'; then
    deny "BLOCKED by pre-commit-guard: git mv is forbidden for agent \"$AGENT_TYPE\" — committer owns all git staging (delegate to committer)"
    exit 0
fi

if printf '%s' "$COMMAND" | grep -qE '\bgit[[:space:]]+restore\b.*--staged\b'; then
    deny "BLOCKED by pre-commit-guard: git restore --staged is forbidden for agent \"$AGENT_TYPE\" — committer owns all git staging (delegate to committer)"
    exit 0
fi

if printf '%s' "$COMMAND" | grep -qE '\bgit[[:space:]]+stash\b'; then
    deny "BLOCKED by pre-commit-guard: git stash is forbidden for agent \"$AGENT_TYPE\" — committer owns all git staging (delegate to committer)"
    exit 0
fi

if printf '%s' "$COMMAND" | grep -qE '\bgit[[:space:]]+commit\b'; then
    deny "BLOCKED by pre-commit-guard: git commit forbidden for agent \"$AGENT_TYPE\" — committer owns commit creation (see CLAUDE.md \"NEVER Commit Directly\")"
    exit 0
fi

if printf '%s' "$COMMAND" | grep -qE '\bgit[[:space:]]+rebase\b'; then
    deny "BLOCKED by pre-commit-guard: git rebase forbidden for agent \"$AGENT_TYPE\" — committer owns history"
    exit 0
fi

if printf '%s' "$COMMAND" | grep -qE '\bgit[[:space:]]+cherry-pick\b'; then
    deny "BLOCKED by pre-commit-guard: git cherry-pick forbidden for agent \"$AGENT_TYPE\" — committer owns history"
    exit 0
fi

if printf '%s' "$COMMAND" | grep -qE '\bgit[[:space:]]+revert\b'; then
    deny "BLOCKED by pre-commit-guard: git revert forbidden for agent \"$AGENT_TYPE\" — committer owns history"
    exit 0
fi

if printf '%s' "$COMMAND" | grep -qE '\bgit[[:space:]]+merge\b'; then
    deny "BLOCKED by pre-commit-guard: git merge forbidden for agent \"$AGENT_TYPE\" — committer owns history"
    exit 0
fi

# git reset --hard / --keep (destructive).
if printf '%s' "$COMMAND" | grep -qE '\bgit[[:space:]]+reset\b.*--hard\b'; then
    deny "BLOCKED by pre-commit-guard: git reset --hard forbidden for agent \"$AGENT_TYPE\" — destructive (use stash or committer)"
    exit 0
fi

# Soft/mixed reset is only allowed when it stays within this cycle's own HEAD.
if printf '%s' "$COMMAND" | grep -qE '\bgit[[:space:]]+reset\b' && ! printf '%s' "$COMMAND" | grep -qE '\bgit[[:space:]]+reset\b.*--hard\b'; then
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
if printf '%s' "$COMMAND" | grep -qE '\bgit[[:space:]]+push\b.*(--force(-with-lease)?|[[:space:]]-f([[:space:]]|$))'; then
    deny "BLOCKED by pre-commit-guard: git push --force forbidden for agent \"$AGENT_TYPE\" — committer owns push discipline"
    exit 0
fi

exit 0
