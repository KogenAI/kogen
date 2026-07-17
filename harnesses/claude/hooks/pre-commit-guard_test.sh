#!/bin/bash
# pre-commit-guard_test.sh — unit tests for pre-commit-guard.sh
#
# Tests:
#   1. git commit is BLOCKED for developer-phoenix-backend (exit 2)
#   2. git status PASSES for developer-phoenix-backend (exit 0)
#   3. git commit PASSES for committer (exit 0)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/pre-commit-guard.sh"
REAL_GIT="$(command -v git)"
FAKE_GIT_DIR="$(mktemp -d)"
trap 'rm -rf "$FAKE_GIT_DIR"' EXIT

cat >"$FAKE_GIT_DIR/git" <<STUB
#!/usr/bin/env bash
if [ "\$1" = "-C" ] && [ "\${3:-}" = "log" ] && [ "\${4:-}" = "-1" ] && [ "\${5:-}" = "--format=%ct" ]; then
    printf '%s\n' "\${FAKE_GIT_HEAD_CT:-}"
    exit 0
fi
exec "$REAL_GIT" "\$@"
STUB
chmod +x "$FAKE_GIT_DIR/git"

pass=0
fail=0

run_test() {
    local desc="$1"
    local expected="$2"
    local input="$3"

    # Capture stdout — the hook now emits a permissionDecision JSON envelope
    # to stdout for deny outcomes (exit 0) instead of stderr + exit 2. We
    # translate the legacy expected values: "2" means "expect deny",
    # "0" means "expect allow (no deny envelope)".
    # Ambient CLAUDE_ROLE/AGENT_TYPE/PI_ROLE (e.g. the developer session
    # running this test suite carries CLAUDE_ROLE=build) must not leak into
    # the fixture — resolve_role()'s CLAUDE_ROLE > PI_ROLE precedence would
    # silently override a test's intended role.
    local stdout
    stdout=$(printf '%s' "$input" | env -u CLAUDE_ROLE -u AGENT_TYPE -u PI_ROLE -u CODEGEN_BUILD_START_TS -u CODEGEN_CYCLE_BASE_SHA bash "$GUARD" 2>/dev/null || true)

    local outcome
    if printf '%s' "$stdout" | grep -q '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"'; then
        outcome="2"
    else
        outcome="0"
    fi

    if [ "$outcome" = "$expected" ]; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s — expected %s (deny=2/allow=0), got %s
  stdout: %s
' "$desc" "$expected" "$outcome" "$stdout"
        fail=$((fail + 1))
    fi
}

# Like run_test but accepts extra env vars as "KEY=value" strings (4th+ args).
run_test_env() {
    local desc="$1"
    local expected="$2"
    local input="$3"
    shift 3
    local env_prefix=""
    for kv in "$@"; do
        env_prefix="$kv $env_prefix"
    done

    # Same ambient-leak isolation as run_test — strip CLAUDE_ROLE/AGENT_TYPE/
    # PI_ROLE from the outer shell before applying the test's explicit
    # env_prefix overrides.
    local stdout
    stdout=$(printf '%s' "$input" | env -u CLAUDE_ROLE -u AGENT_TYPE -u PI_ROLE -u CODEGEN_BUILD_START_TS -u CODEGEN_CYCLE_BASE_SHA $env_prefix bash "$GUARD" 2>/dev/null || true)

    local outcome
    if printf '%s' "$stdout" | grep -q '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"'; then
        outcome="2"
    else
        outcome="0"
    fi

    if [ "$outcome" = "$expected" ]; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s — expected %s (deny=2/allow=0), got %s
  stdout: %s
' "$desc" "$expected" "$outcome" "$stdout"
        fail=$((fail + 1))
    fi
}

# Test 1: git commit is BLOCKED for developer-phoenix-backend
FIXTURE_COMMIT_BLOCKED='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git commit -m '\''foo'\''"},"agent_type":"developer-phoenix-backend","agent_id":"abc123"}'
run_test "git commit blocked for developer-phoenix-backend" "2" "$FIXTURE_COMMIT_BLOCKED"

# Test 2: git status PASSES for developer-phoenix-backend
FIXTURE_STATUS_ALLOWED='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git status"},"agent_type":"developer-phoenix-backend","agent_id":"abc123"}'
run_test "git status passes for developer-phoenix-backend" "0" "$FIXTURE_STATUS_ALLOWED"

# Test 2b: git commit-graph PASSES for developer-phoenix-backend (word-boundary
# fix: `git commit` must NOT substring-match `git commit-graph`/`commit-tree`)
FIXTURE_COMMIT_GRAPH_ALLOWED='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git commit-graph write"},"agent_type":"developer-phoenix-backend","agent_id":"abc123"}'
run_test "git commit-graph passes for developer-phoenix-backend" "0" "$FIXTURE_COMMIT_GRAPH_ALLOWED"

# Test 3: git commit PASSES for committer
FIXTURE_COMMIT_ALLOWED='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git commit -m '\''foo'\''"},"agent_type":"committer","agent_id":"abc123"}'
run_test "git commit passes for committer" "0" "$FIXTURE_COMMIT_ALLOWED"

# Test 4: debug role + read-only Bash (journalctl) — MUST ALLOW
# Regression: prior code blanket-denied all Bash in debug sessions.
FIXTURE_DEBUG_READONLY='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"journalctl -u app --since \"5m ago\""},"agent_type":"","agent_id":"a"}'
run_test_env "debug role + journalctl allowed" "0" "$FIXTURE_DEBUG_READONLY" "CLAUDE_ROLE=debug"

# Test 5: debug role + git commit — MUST DENY
# Debug sessions must not bypass committer-only rule.
FIXTURE_DEBUG_COMMIT='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git commit -m foo"},"agent_type":"","agent_id":"a"}'
run_test_env "debug role + git commit denied" "2" "$FIXTURE_DEBUG_COMMIT" "CLAUDE_ROLE=debug"

# Test 6: git rebase for non-committer — MUST DENY
FIXTURE_REBASE='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git rebase -i HEAD~3"},"agent_type":"developer-phoenix-backend","agent_id":"a"}'
run_test "git rebase denied for non-committer" "2" "$FIXTURE_REBASE"

# Test 7: git cherry-pick for non-committer — MUST DENY
FIXTURE_CHERRY_PICK='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git cherry-pick abc123"},"agent_type":"reviewer-phoenix","agent_id":"a"}'
run_test "git cherry-pick denied for non-committer" "2" "$FIXTURE_CHERRY_PICK"

# Test 8: git push --force for non-committer — MUST DENY
FIXTURE_PUSH_FORCE='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git push --force origin main"},"agent_type":"developer-phoenix-backend","agent_id":"a"}'
run_test "git push --force denied for non-committer" "2" "$FIXTURE_PUSH_FORCE"

# Test 9: git reset --hard for non-committer — MUST DENY
FIXTURE_RESET_HARD='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git reset --hard HEAD~1"},"agent_type":"developer-phoenix-frontend","agent_id":"a"}'
run_test "git reset --hard denied for non-committer" "2" "$FIXTURE_RESET_HARD"

# Test 10: git reset (soft) for non-committer — MUST ALLOW
FIXTURE_RESET_SOFT='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git reset HEAD~1"},"agent_type":"developer-phoenix-backend","agent_id":"a"}'
run_test "git reset soft allowed for non-committer" "0" "$FIXTURE_RESET_SOFT"

# Test 11: git reset (soft) for non-committer — MUST DENY when HEAD predates cycle start
FIXTURE_RESET_FOREIGN='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git reset HEAD~1"},"agent_type":"developer-phoenix-backend","agent_id":"a"}'
run_test_env "git reset soft denied for foreign commit" "2" "$FIXTURE_RESET_FOREIGN" \
    "PATH=$FAKE_GIT_DIR:$PATH" \
    "FAKE_GIT_HEAD_CT=1700000000" \
    "CODEGEN_BUILD_START_TS=1700000100"

# Test 12: git reset (soft) for non-committer — MUST ALLOW for this cycle's own HEAD
FIXTURE_RESET_OWN='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git reset HEAD~1"},"agent_type":"developer-phoenix-backend","agent_id":"a"}'
run_test_env "git reset soft allowed for current-cycle commit" "0" "$FIXTURE_RESET_OWN" \
    "PATH=$FAKE_GIT_DIR:$PATH" \
    "FAKE_GIT_HEAD_CT=1700000200" \
    "CODEGEN_BUILD_START_TS=1700000100"

# Ops role alone no longer unlocks destructive git — a two-signal gate now
# requires CODEGEN_OPS_GIT_UNLOCK=1 ALSO set, per the fail-closed-everywhere
# ruling (role alone was a single-signal bypass that fail-open'd on a typo'd
# or stray CLAUDE_ROLE=ops in the environment).

# Test 11: ops role + git commit + CODEGEN_OPS_GIT_UNLOCK=1 — MUST ALLOW (two-signal gate satisfied)
FIXTURE_OPS_COMMIT='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git commit -m \"hotfix: patch config\""},"agent_type":"","agent_id":"a"}'
run_test_env "ops role + unlock + git commit allowed" "0" "$FIXTURE_OPS_COMMIT" "CLAUDE_ROLE=ops" "CODEGEN_OPS_GIT_UNLOCK=1"

# Test 12: ops role + git reset --hard + CODEGEN_OPS_GIT_UNLOCK=1 — MUST ALLOW
FIXTURE_OPS_RESET='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git reset --hard HEAD~1"},"agent_type":"","agent_id":"a"}'
run_test_env "ops role + unlock + git reset --hard allowed" "0" "$FIXTURE_OPS_RESET" "CLAUDE_ROLE=ops" "CODEGEN_OPS_GIT_UNLOCK=1"

# Test 13: ops role + git push --force + CODEGEN_OPS_GIT_UNLOCK=1 — MUST ALLOW
FIXTURE_OPS_PUSH='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git push --force origin main"},"agent_type":"","agent_id":"a"}'
run_test_env "ops role + unlock + git push --force allowed" "0" "$FIXTURE_OPS_PUSH" "CLAUDE_ROLE=ops" "CODEGEN_OPS_GIT_UNLOCK=1"

# Test 14: PI_ROLE=ops + CODEGEN_OPS_GIT_UNLOCK=1 + git commit — MUST ALLOW (parity with CLAUDE_ROLE=ops)
FIXTURE_PI_OPS_COMMIT='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git commit -m \"pi-ops hotfix\""},"agent_type":"","agent_id":"a"}'
run_test_env "PI_ROLE=ops + unlock + git commit allowed" "0" "$FIXTURE_PI_OPS_COMMIT" "PI_ROLE=ops" "CODEGEN_OPS_GIT_UNLOCK=1"

# Test 14b: ops role WITHOUT CODEGEN_OPS_GIT_UNLOCK — MUST DENY (two-signal gate: role alone insufficient)
FIXTURE_OPS_ALONE_COMMIT='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git commit -m \"hotfix\""},"agent_type":"","agent_id":"a"}'
run_test_env "ops role alone (no unlock) + git commit denied" "2" "$FIXTURE_OPS_ALONE_COMMIT" "CLAUDE_ROLE=ops"

FIXTURE_OPS_ALONE_RESET='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git reset --hard HEAD~1"},"agent_type":"","agent_id":"a"}'
run_test_env "ops role alone (no unlock) + git reset --hard denied" "2" "$FIXTURE_OPS_ALONE_RESET" "CLAUDE_ROLE=ops"

FIXTURE_OPS_ALONE_PUSH='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git push --force origin main"},"agent_type":"","agent_id":"a"}'
run_test_env "ops role alone (no unlock) + git push --force denied" "2" "$FIXTURE_OPS_ALONE_PUSH" "CLAUDE_ROLE=ops"

# Test 14c: PI_ROLE=ops + CODEGEN_OPS_GIT_UNLOCK=1 — MUST ALLOW (parity, two-signal satisfied)
FIXTURE_PI_OPS_UNLOCK='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git commit -m \"pi-ops unlock\""},"agent_type":"","agent_id":"a"}'
run_test_env "PI_ROLE=ops + CODEGEN_OPS_GIT_UNLOCK=1 allowed (parity)" "0" "$FIXTURE_PI_OPS_UNLOCK" "PI_ROLE=ops" "CODEGEN_OPS_GIT_UNLOCK=1"

# Test 15: git add -A for non-committer — MUST DENY
FIXTURE_ADD_BLOCKED='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git add -A"},"agent_type":"developer-phoenix-backend","agent_id":"a"}'
run_test "git add -A blocked for non-committer" "2" "$FIXTURE_ADD_BLOCKED"

# Test 16: git add -A for committer — MUST ALLOW
FIXTURE_ADD_COMMITTER='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git add -A"},"agent_type":"committer","agent_id":"a"}'
run_test "git add -A passes for committer" "0" "$FIXTURE_ADD_COMMITTER"

# Test 17: git add -A in ops mode + CODEGEN_OPS_GIT_UNLOCK=1 — MUST ALLOW
FIXTURE_ADD_OPS='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git add -A"},"agent_type":"","agent_id":"a"}'
run_test_env "git add -A allowed in ops mode + unlock" "0" "$FIXTURE_ADD_OPS" "CLAUDE_ROLE=ops" "CODEGEN_OPS_GIT_UNLOCK=1"

# Test 17b: git add -A in ops mode WITHOUT CODEGEN_OPS_GIT_UNLOCK — MUST DENY
FIXTURE_ADD_OPS_ALONE='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git add -A"},"agent_type":"","agent_id":"a"}'
run_test_env "git add -A denied in ops mode alone (no unlock)" "2" "$FIXTURE_ADD_OPS_ALONE" "CLAUDE_ROLE=ops"

# Test 18: git stash — arm REMOVED from pre-commit-guard (hook-hygiene-sweep):
# no-git-stash.sh already denies `git stash` for role `*` with no exemption,
# strictly broader coverage. See no-git-stash_test.sh for the live DENY case.
FIXTURE_STASH_NOW_PASSTHROUGH='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git stash"},"agent_type":"developer-phoenix-backend","agent_id":"a"}'
run_test "git stash no longer gated by pre-commit-guard (no-git-stash.sh owns it)" "0" "$FIXTURE_STASH_NOW_PASSTHROUGH"

# Test 19: git rm --cached foo for non-committer — MUST DENY
FIXTURE_RM_BLOCKED='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git rm --cached foo"},"agent_type":"developer-phoenix-backend","agent_id":"a"}'
run_test "git rm --cached blocked for non-committer" "2" "$FIXTURE_RM_BLOCKED"

# Test 20: git mv a b for non-committer — MUST DENY
FIXTURE_MV_BLOCKED='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git mv a b"},"agent_type":"developer-phoenix-backend","agent_id":"a"}'
run_test "git mv blocked for non-committer" "2" "$FIXTURE_MV_BLOCKED"

# Test 21: git restore --staged foo for non-committer — MUST DENY
FIXTURE_RESTORE_STAGED_BLOCKED='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git restore --staged foo"},"agent_type":"developer-phoenix-backend","agent_id":"a"}'
run_test "git restore --staged blocked for non-committer" "2" "$FIXTURE_RESTORE_STAGED_BLOCKED"

# Test 22: git restore foo (NO --staged) for non-committer — MUST DENY (leg D:
# plain `restore` can discard uncommitted working-tree edits just like
# `restore --staged`; the plain-restore branch SUBSUMES --staged and is a
# hard flip from the prior "allowed" assertion.)
FIXTURE_RESTORE_ALLOWED='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git restore foo"},"agent_type":"developer-phoenix-backend","agent_id":"a"}'
run_test "git restore (no --staged) denied for non-committer (leg D flip)" "2" "$FIXTURE_RESTORE_ALLOWED"

# Test 22b: git checkout -- <path> for non-committer — MUST DENY (leg D)
FIXTURE_CHECKOUT_PATH='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git checkout -- foo.ex"},"agent_type":"developer-phoenix-backend","agent_id":"a"}'
run_test "git checkout -- <path> denied for non-committer (leg D)" "2" "$FIXTURE_CHECKOUT_PATH"

# Test 22c: git switch <branch> for non-committer — MUST DENY (leg D)
FIXTURE_SWITCH='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git switch main"},"agent_type":"developer-phoenix-backend","agent_id":"a"}'
run_test "git switch denied for non-committer (leg D)" "2" "$FIXTURE_SWITCH"

# Test 22d: git clean -fd for non-committer — MUST DENY (leg D)
FIXTURE_CLEAN_FD='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git clean -fd"},"agent_type":"developer-phoenix-backend","agent_id":"a"}'
run_test "git clean -fd denied for non-committer (leg D)" "2" "$FIXTURE_CLEAN_FD"

# Test 22e: git clean -n (dry-run) for non-committer — MUST ALLOW (carve-out)
FIXTURE_CLEAN_DRYRUN='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git clean -n"},"agent_type":"developer-phoenix-backend","agent_id":"a"}'
run_test "git clean -n (dry-run) allowed for non-committer (carve-out)" "0" "$FIXTURE_CLEAN_DRYRUN"

# Test 22f: git clean --dry-run for non-committer — MUST ALLOW (carve-out)
FIXTURE_CLEAN_DRYRUN_LONG='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git clean --dry-run -fd"},"agent_type":"developer-phoenix-backend","agent_id":"a"}'
run_test "git clean --dry-run allowed for non-committer (carve-out)" "0" "$FIXTURE_CLEAN_DRYRUN_LONG"

# Test 22g: git reset --merge for non-committer — MUST DENY (leg D)
FIXTURE_RESET_MERGE='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git reset --merge HEAD~1"},"agent_type":"developer-phoenix-backend","agent_id":"a"}'
run_test "git reset --merge denied for non-committer (leg D)" "2" "$FIXTURE_RESET_MERGE"

# Test 22h: git reset --keep for non-committer — MUST DENY (leg D)
FIXTURE_RESET_KEEP='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git reset --keep HEAD~1"},"agent_type":"developer-phoenix-backend","agent_id":"a"}'
run_test "git reset --keep denied for non-committer (leg D)" "2" "$FIXTURE_RESET_KEEP"

# Test 22i: committer STILL allowed for git checkout/restore/clean/switch (actor gate unaffected)
FIXTURE_COMMITTER_CHECKOUT='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git checkout -- foo.ex"},"agent_type":"committer","agent_id":"a"}'
run_test "git checkout -- still allowed for committer (leg D)" "0" "$FIXTURE_COMMITTER_CHECKOUT"

FIXTURE_COMMITTER_RESTORE='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git restore foo"},"agent_type":"committer","agent_id":"a"}'
run_test "git restore still allowed for committer (leg D)" "0" "$FIXTURE_COMMITTER_RESTORE"

FIXTURE_COMMITTER_CLEAN='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git clean -fd"},"agent_type":"committer","agent_id":"a"}'
run_test "git clean -fd still allowed for committer (leg D)" "0" "$FIXTURE_COMMITTER_CLEAN"

FIXTURE_COMMITTER_SWITCH='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git switch main"},"agent_type":"committer","agent_id":"a"}'
run_test "git switch still allowed for committer (leg D)" "0" "$FIXTURE_COMMITTER_SWITCH"

# Test 22j: ops mode + git checkout WITHOUT unlock — MUST DENY (leg D ops-arm widened)
FIXTURE_OPS_CHECKOUT='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git checkout -- foo.ex"},"agent_type":"","agent_id":"a"}'
run_test_env "ops mode git checkout without unlock denied (leg D)" "2" "$FIXTURE_OPS_CHECKOUT" "CLAUDE_ROLE=ops"

# Test 22k: ops mode + git checkout WITH unlock — MUST ALLOW
FIXTURE_OPS_CHECKOUT_UNLOCK='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git checkout -- foo.ex"},"agent_type":"","agent_id":"a"}'
run_test_env "ops mode git checkout with unlock allowed (leg D)" "0" "$FIXTURE_OPS_CHECKOUT_UNLOCK" "CLAUDE_ROLE=ops" "CODEGEN_OPS_GIT_UNLOCK=1"

# Test 22l: ops mode + git clean -n (dry-run) — MUST ALLOW without unlock (carve-out honored in ops arm too)
FIXTURE_OPS_CLEAN_DRYRUN='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git clean -n"},"agent_type":"","agent_id":"a"}'
run_test_env "ops mode git clean -n allowed without unlock (carve-out)" "0" "$FIXTURE_OPS_CLEAN_DRYRUN" "CLAUDE_ROLE=ops"

# Test 22m: git show HEAD:<path> for non-committer — MUST ALLOW (the taught substitute)
FIXTURE_SHOW_HEAD='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git show HEAD:lib/foo.ex"},"agent_type":"developer-phoenix-backend","agent_id":"a"}'
run_test "git show HEAD:<path> allowed for non-committer (substitute)" "0" "$FIXTURE_SHOW_HEAD"

# ── ops-mode scope regression: gate must not blanket-deny all Bash for ops ──
# Bug: the ops branch previously returned a verdict for ALL Bash before
# checking whether it was even a git command. Fix scopes the ops branch to
# destructive-git verbs only; non-git Bash and read-only git pass straight
# through regardless of CODEGEN_OPS_GIT_UNLOCK.

# RED-then-GREEN proof: confirm a PRE-fix body (returns a deny verdict for
# ALL Bash under ops before even checking whether the command is git) denies
# ops non-git Bash (proves the historical bug), then confirm the fixed
# working-tree body allows it (Test 25 below).
#
# NOTE: this used to pull the "pre-fix" body via `git show HEAD:<file>`, but
# that self-invalidates the instant the fix lands at HEAD (`git show HEAD`
# then fetches the ALREADY-FIXED script and the RED branch can never fire —
# see context/bash-patterns.md "RED-then-GREEN proof via floating git show HEAD
# self-invalidates once fix lands"). Fixed by synthesizing the exact
# historical buggy body as a literal fixture instead of depending on git
# history. Written into a mktemp -d scratch dir (never into the live hooks
# source dir — a stray non-hook file there breaks `hook_registrations.py`'s
# HOOK-MANIFEST parity check and hangs around if the process is killed) with
# lib/ and _role.sh symlinked back so the relative `dirname "$0"` sourcing
# still resolves.
PRE_FIX_DIR="$(mktemp -d)"
ln -s "$SCRIPT_DIR/lib" "$PRE_FIX_DIR/lib"
ln -s "$SCRIPT_DIR/_role.sh" "$PRE_FIX_DIR/_role.sh"
PRE_FIX_GUARD="$PRE_FIX_DIR/pre-commit-guard.pre-fix.sh"
trap 'rm -rf "$FAKE_GIT_DIR"; rm -rf "$PRE_FIX_DIR"' EXIT
cat >"$PRE_FIX_GUARD" <<'PREFIXEOF'
#!/bin/bash
# Synthetic pre-fix fixture: reproduces the historical bug where the ops
# branch returned a deny verdict for ALL Bash (never checked whether the
# command was even a git invocation before denying).
set -u
source "$(dirname "$0")/lib/hooks-lib.sh"
source "$(dirname "$0")/_role.sh"
parse_input
debug_log pre-commit-guard "tool=$TOOL_NAME agent=$AGENT_TYPE cmd=$COMMAND"
if [ "$TOOL_NAME" != "Bash" ]; then
    exit 0
fi
_role=$(resolve_role)
if [ "$_role" = "ops" ]; then
    deny "BLOCKED by pre-commit-guard: ops role denied unconditionally (historical bug — no git-ness check)."
    exit 0
fi
exit 0
PREFIXEOF

FIXTURE_RED_PROOF='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ssh box \"hostname\""},"agent_type":"","agent_id":"a"}'
pre_fix_stdout=$(printf '%s' "$FIXTURE_RED_PROOF" |
    env CLAUDE_ROLE=ops bash "$PRE_FIX_GUARD" 2>/dev/null || true)
if printf '%s' "$pre_fix_stdout" | grep -q '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"'; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS (RED): pre-fix body denies ops non-git Bash (bug confirmed)\n'
    pass=$((pass + 1))
else
    printf 'FAIL (RED): pre-fix body did NOT deny ops non-git Bash — RED proof invalid\n'
    fail=$((fail + 1))
fi

# Test 25: ops role + non-git Bash (ssh) — MUST ALLOW (no unlock needed)
FIXTURE_OPS_SSH='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ssh box \"hostname\""},"agent_type":"","agent_id":"a"}'
run_test_env "ops role + non-git ssh allowed (no unlock needed)" "0" "$FIXTURE_OPS_SSH" "CLAUDE_ROLE=ops"

# Test 26: ops role + non-git Bash (ls -la) — MUST ALLOW
FIXTURE_OPS_LS='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls -la"},"agent_type":"","agent_id":"a"}'
run_test_env "ops role + ls -la allowed (no unlock needed)" "0" "$FIXTURE_OPS_LS" "CLAUDE_ROLE=ops"

# Test 27: ops role + non-git Bash (cp) — MUST ALLOW
FIXTURE_OPS_CP='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"cp a b"},"agent_type":"","agent_id":"a"}'
run_test_env "ops role + cp a b allowed (no unlock needed)" "0" "$FIXTURE_OPS_CP" "CLAUDE_ROLE=ops"

# Test 28: ops role + git status — MUST ALLOW
FIXTURE_OPS_STATUS='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git status"},"agent_type":"","agent_id":"a"}'
run_test_env "ops role + git status allowed" "0" "$FIXTURE_OPS_STATUS" "CLAUDE_ROLE=ops"

# Test 29: ops role + git diff — MUST ALLOW
FIXTURE_OPS_DIFF='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git diff"},"agent_type":"","agent_id":"a"}'
run_test_env "ops role + git diff allowed" "0" "$FIXTURE_OPS_DIFF" "CLAUDE_ROLE=ops"

# Test 30: ops role + git log — MUST ALLOW
FIXTURE_OPS_LOG='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git log"},"agent_type":"","agent_id":"a"}'
run_test_env "ops role + git log allowed" "0" "$FIXTURE_OPS_LOG" "CLAUDE_ROLE=ops"

# Test 31: ops role + destructive git (commit) WITHOUT unlock — MUST DENY
FIXTURE_OPS_SCOPE_COMMIT='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git commit -m \"x\""},"agent_type":"","agent_id":"a"}'
run_test_env "ops role + destructive git commit without unlock denied" "2" "$FIXTURE_OPS_SCOPE_COMMIT" "CLAUDE_ROLE=ops"

# Test 32: ops role + destructive git (reset --hard) WITHOUT unlock — MUST DENY
FIXTURE_OPS_SCOPE_RESET='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git reset --hard HEAD~1"},"agent_type":"","agent_id":"a"}'
run_test_env "ops role + destructive git reset --hard without unlock denied" "2" "$FIXTURE_OPS_SCOPE_RESET" "CLAUDE_ROLE=ops"

# Test 33: ops role + destructive git (push --force) WITHOUT unlock — MUST DENY
FIXTURE_OPS_SCOPE_PUSH='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git push --force origin main"},"agent_type":"","agent_id":"a"}'
run_test_env "ops role + destructive git push --force without unlock denied" "2" "$FIXTURE_OPS_SCOPE_PUSH" "CLAUDE_ROLE=ops"

# Test 34: ops role + destructive git (commit) WITH unlock — MUST ALLOW
FIXTURE_OPS_SCOPE_COMMIT_UNLOCK='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git commit -m \"x\""},"agent_type":"","agent_id":"a"}'
run_test_env "ops role + destructive git commit with unlock allowed" "0" "$FIXTURE_OPS_SCOPE_COMMIT_UNLOCK" "CLAUDE_ROLE=ops" "CODEGEN_OPS_GIT_UNLOCK=1"

# ── codegen-log carve-out: piped body prose containing git-verb tokens ─────
# Every role's session-log section body is written via `printf '%s' "$body" |
# codegen-log section --body @-`. The piped body is arbitrary role-authored
# prose that may legitimately describe a git operation (e.g. "verified git
# commit -m done"). This must ALLOW for a non-committer role because the
# codegen-log carve-out exits before the git-verb scans run — the body is
# DATA to codegen-log, never executed. Bare history-mutating git commands
# (not routed through codegen-log) remain denied.

# Test 23: non-committer codegen-log body with "git commit" prose — MUST ALLOW
FIXTURE_LOG_GIT_VERB='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"printf %s \"Verified git commit -m done\" | codegen-log section --body @-"},"agent_type":"reviewer-phoenix","agent_id":"a"}'
run_test "non-committer codegen-log body with 'git commit' prose allowed (carve-out)" "0" "$FIXTURE_LOG_GIT_VERB"

# Test 24: non-committer bare "git commit" (NOT via codegen-log) — MUST DENY
FIXTURE_BARE_COMMIT='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git commit -m \"x\""},"agent_type":"reviewer-phoenix","agent_id":"a"}'
run_test "non-committer bare git commit (no codegen-log) still denied" "2" "$FIXTURE_BARE_COMMIT"

# ── quote-strip fail-closed regression (this pitch) ─────────────────────────
# The guard must block only a REAL, LOCAL git-verb invocation. A git verb
# sitting inside a quoted remote-exec payload or a quoted string argument to
# another command is not that action; strip_quoted() removes such spans
# before the scan so these bypass, while a real unquoted invocation still
# matches and is still denied.

# Test 35: ssh remote payload with "git stash" inside quotes — MUST ALLOW
# for a non-committer role (not a real local invocation).
FIXTURE_SSH_STASH_PAYLOAD='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ssh box \"git stash\""},"agent_type":"developer-phoenix-backend","agent_id":"a"}'
run_test "ssh remote git-stash payload (quoted) allowed for non-committer" "0" "$FIXTURE_SSH_STASH_PAYLOAD"

# Test 36: "git add" mentioned inside a quoted grep pattern — MUST ALLOW
# (quoted string argument, not a real local invocation).
FIXTURE_GREP_GIT_ADD='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"grep -n \"git add\" notes.md"},"agent_type":"developer-phoenix-backend","agent_id":"a"}'
run_test "git add mentioned in quoted grep arg allowed" "0" "$FIXTURE_GREP_GIT_ADD"

# Test 37: real unquoted local "git rebase" still denied (fail-closed sanity,
# distinct from Test 6 — the verb itself is unquoted even though this fixture
# has no trailing quoted arg at all).
FIXTURE_REBASE_UNQUOTED='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git rebase --continue"},"agent_type":"developer-phoenix-backend","agent_id":"a"}'
run_test "real unquoted git rebase still denied (fail-closed sanity)" "2" "$FIXTURE_REBASE_UNQUOTED"

# Test 38: quoted trailing arg does NOT strip the unquoted leading verb —
# "git commit -m 'foo'" must still deny (verb precedes the quoted span).
FIXTURE_COMMIT_QUOTED_ARG='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git commit -m '\''quoted message'\''"},"agent_type":"developer-phoenix-backend","agent_id":"a"}'
run_test "git commit with quoted -m arg still denied (verb unquoted)" "2" "$FIXTURE_COMMIT_QUOTED_ARG"

# Test 39: ops mode + destructive git verb inside quoted ssh payload — MUST
# ALLOW even without CODEGEN_OPS_GIT_UNLOCK (not a real local invocation;
# the ops-mode branch also applies strip_quoted before its scan).
FIXTURE_OPS_SSH_STASH='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ssh box \"git stash\""},"agent_type":"","agent_id":"a"}'
run_test_env "ops role + ssh remote git-stash payload (quoted) allowed without unlock" "0" "$FIXTURE_OPS_SSH_STASH" "CLAUDE_ROLE=ops"

# ── git global-option evasion regression (this pitch) ───────────────────────
# git's global options (-C <path>, --git-dir=, -c k=v, --no-pager, ...) may
# sit between `git` and its subcommand. Every verb regex assumed `git` was
# immediately followed by the verb token — `git -C /tmp/x commit -m y`
# evaded the match entirely. strip_git_global_opts() normalizes these before
# matching; every verb arm (+ ops arm) must now deny the evaded form too.

# Test 40: git -C <dir> commit for non-committer — MUST DENY (the reported evasion)
FIXTURE_C_COMMIT='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git -C /tmp/x commit -m y"},"agent_type":"developer-phoenix-backend","agent_id":"a"}'
run_test "git -C <dir> commit denied for non-committer (global-opt evasion closed)" "2" "$FIXTURE_C_COMMIT"

# Test 41: git --git-dir=<x> add for non-committer — MUST DENY
FIXTURE_GITDIR_ADD='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git --git-dir=/tmp/x/.git add -A"},"agent_type":"developer-phoenix-backend","agent_id":"a"}'
run_test "git --git-dir=<x> add denied for non-committer" "2" "$FIXTURE_GITDIR_ADD"

# Test 42: git -c k=v rm for non-committer — MUST DENY
FIXTURE_C_OPT_RM='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git -c user.name=x rm foo"},"agent_type":"developer-phoenix-backend","agent_id":"a"}'
run_test "git -c k=v rm denied for non-committer" "2" "$FIXTURE_C_OPT_RM"

# Test 43: git -C <dir> mv for non-committer — MUST DENY
FIXTURE_C_MV='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git -C /tmp/x mv a b"},"agent_type":"developer-phoenix-backend","agent_id":"a"}'
run_test "git -C <dir> mv denied for non-committer" "2" "$FIXTURE_C_MV"

# Test 44: git -C <dir> restore --staged for non-committer — MUST DENY
FIXTURE_C_RESTORE='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git -C /tmp/x restore --staged foo"},"agent_type":"developer-phoenix-backend","agent_id":"a"}'
run_test "git -C <dir> restore --staged denied for non-committer" "2" "$FIXTURE_C_RESTORE"

# Test 45: git -C <dir> rebase for non-committer — MUST DENY
FIXTURE_C_REBASE='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git -C /tmp/x rebase -i HEAD~3"},"agent_type":"developer-phoenix-backend","agent_id":"a"}'
run_test "git -C <dir> rebase denied for non-committer" "2" "$FIXTURE_C_REBASE"

# Test 46: git -C <dir> cherry-pick for non-committer — MUST DENY
FIXTURE_C_CHERRY='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git -C /tmp/x cherry-pick abc123"},"agent_type":"developer-phoenix-backend","agent_id":"a"}'
run_test "git -C <dir> cherry-pick denied for non-committer" "2" "$FIXTURE_C_CHERRY"

# Test 47: git -C <dir> revert for non-committer — MUST DENY
FIXTURE_C_REVERT='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git -C /tmp/x revert HEAD"},"agent_type":"developer-phoenix-backend","agent_id":"a"}'
run_test "git -C <dir> revert denied for non-committer" "2" "$FIXTURE_C_REVERT"

# Test 48: git -C <dir> merge for non-committer — MUST DENY
FIXTURE_C_MERGE='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git -C /tmp/x merge other-branch"},"agent_type":"developer-phoenix-backend","agent_id":"a"}'
run_test "git -C <dir> merge denied for non-committer" "2" "$FIXTURE_C_MERGE"

# Test 49: git -C <dir> push --force for non-committer — MUST DENY
FIXTURE_C_PUSH='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git -C /tmp/x push --force origin main"},"agent_type":"developer-phoenix-backend","agent_id":"a"}'
run_test "git -C <dir> push --force denied for non-committer" "2" "$FIXTURE_C_PUSH"

# Test 50: git -C <dir> reset --hard for non-committer — MUST DENY
FIXTURE_C_RESET_HARD='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git -C /tmp/x reset --hard HEAD~1"},"agent_type":"developer-phoenix-backend","agent_id":"a"}'
run_test "git -C <dir> reset --hard denied for non-committer" "2" "$FIXTURE_C_RESET_HARD"

# Test 51: committer STILL allowed for git -C <dir> commit (actor gate unaffected)
FIXTURE_C_COMMIT_COMMITTER='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git -C /tmp/x commit -m y"},"agent_type":"committer","agent_id":"a"}'
run_test "git -C <dir> commit still allowed for committer" "0" "$FIXTURE_C_COMMIT_COMMITTER"

# Test 52: ops mode + git -C <dir> commit WITHOUT unlock — MUST DENY (ops-arm evasion closed)
FIXTURE_OPS_C_COMMIT='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git -C /tmp/x commit -m y"},"agent_type":"","agent_id":"a"}'
run_test_env "ops mode git -C <dir> commit without unlock denied (global-opt evasion closed)" "2" "$FIXTURE_OPS_C_COMMIT" "CLAUDE_ROLE=ops"

# Test 53: git -C <dir> status for non-committer — MUST ALLOW (read-only verb unaffected)
FIXTURE_C_STATUS='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git -C /tmp/x status"},"agent_type":"developer-phoenix-backend","agent_id":"a"}'
run_test "git -C <dir> status still allowed for non-committer (read-only unaffected)" "0" "$FIXTURE_C_STATUS"

# ── indirection expansion: bash <file> body-scan (a-guard-on-a-verb) ────────
INDIRECTION_TMPDIR="$(mktemp -d)"
trap 'rm -rf "$FAKE_GIT_DIR" "$INDIRECTION_TMPDIR"' EXIT

# Test 54: bash <file with git reset --hard> for non-committer — MUST DENY
# (the door stays shut: the base string "bash /tmp/x.sh" carries no
# forbidden verb; only the referenced file's BODY does.)
printf 'git reset --hard HEAD~1\n' >"$INDIRECTION_TMPDIR/danger.sh"
FIXTURE_INDIRECT_RESET_HARD="{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"bash $INDIRECTION_TMPDIR/danger.sh\"},\"agent_type\":\"developer-phoenix-backend\",\"agent_id\":\"a\"}"
run_test "bash <file with git reset --hard body> denied for non-committer (indirection)" "2" "$FIXTURE_INDIRECT_RESET_HARD"

# Test 55: bash <file with benign body> for non-committer — MUST ALLOW (no false new deny)
printf 'echo hello world\n' >"$INDIRECTION_TMPDIR/benign.sh"
FIXTURE_INDIRECT_BENIGN="{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"bash $INDIRECTION_TMPDIR/benign.sh\"},\"agent_type\":\"developer-phoenix-backend\",\"agent_id\":\"a\"}"
run_test "bash <file with benign body> allowed for non-committer (no regression)" "0" "$FIXTURE_INDIRECT_BENIGN"

# Test 56: bash "$dynamic" (unresolvable path) — MUST ALLOW (unresolvable -> base string-match only)
FIXTURE_INDIRECT_DYNAMIC='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"bash \"$dynamic\""},"agent_type":"developer-phoenix-backend","agent_id":"a"}'
run_test "bash \"\$dynamic\" (unresolvable) allowed for non-committer (no regression)" "0" "$FIXTURE_INDIRECT_DYNAMIC"

# Test 57: committer STILL allowed for bash <file with git reset --hard body> (actor gate unaffected)
FIXTURE_INDIRECT_COMMITTER="{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"bash $INDIRECTION_TMPDIR/danger.sh\"},\"agent_type\":\"committer\",\"agent_id\":\"a\"}"
run_test "bash <file with git reset --hard body> still allowed for committer (actor gate unaffected)" "0" "$FIXTURE_INDIRECT_COMMITTER"

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
