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
    local stdout
    stdout=$(printf '%s' "$input" | bash "$GUARD" 2>/dev/null || true)

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

    local stdout
    stdout=$(printf '%s' "$input" | env $env_prefix bash "$GUARD" 2>/dev/null || true)

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

# Test 18: git stash for non-committer — MUST DENY
FIXTURE_STASH_BLOCKED='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git stash"},"agent_type":"developer-phoenix-backend","agent_id":"a"}'
run_test "git stash blocked for non-committer" "2" "$FIXTURE_STASH_BLOCKED"

# Test 19: git rm --cached foo for non-committer — MUST DENY
FIXTURE_RM_BLOCKED='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git rm --cached foo"},"agent_type":"developer-phoenix-backend","agent_id":"a"}'
run_test "git rm --cached blocked for non-committer" "2" "$FIXTURE_RM_BLOCKED"

# Test 20: git mv a b for non-committer — MUST DENY
FIXTURE_MV_BLOCKED='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git mv a b"},"agent_type":"developer-phoenix-backend","agent_id":"a"}'
run_test "git mv blocked for non-committer" "2" "$FIXTURE_MV_BLOCKED"

# Test 21: git restore --staged foo for non-committer — MUST DENY
FIXTURE_RESTORE_STAGED_BLOCKED='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git restore --staged foo"},"agent_type":"developer-phoenix-backend","agent_id":"a"}'
run_test "git restore --staged blocked for non-committer" "2" "$FIXTURE_RESTORE_STAGED_BLOCKED"

# Test 22: git restore foo (NO --staged) for non-committer — MUST ALLOW
FIXTURE_RESTORE_ALLOWED='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git restore foo"},"agent_type":"developer-phoenix-backend","agent_id":"a"}'
run_test "git restore (no --staged) allowed for non-committer" "0" "$FIXTURE_RESTORE_ALLOWED"

# ── ops-mode scope regression: gate must not blanket-deny all Bash for ops ──
# Bug: the ops branch previously returned a verdict for ALL Bash before
# checking whether it was even a git command. Fix scopes the ops branch to
# destructive-git verbs only; non-git Bash and read-only git pass straight
# through regardless of CODEGEN_OPS_GIT_UNLOCK.

# RED-then-GREEN proof: confirm the PRE-fix committed body denies ops
# non-git Bash (proves the bug existed), then confirm the fixed working-tree
# body allows it. Written INTO SCRIPT_DIR (not /tmp) so the relative
# `dirname "$0"` sourcing of lib/hooks-lib.sh and _role.sh still resolves.
PRE_FIX_GUARD="$SCRIPT_DIR/.pre-commit-guard.pre-fix.sh"
trap 'rm -rf "$FAKE_GIT_DIR"; rm -f "$PRE_FIX_GUARD"' EXIT
git -C "$SCRIPT_DIR" show HEAD:harnesses/claude/hooks/pre-commit-guard.sh >"$PRE_FIX_GUARD" 2>/dev/null || true

if [ -s "$PRE_FIX_GUARD" ]; then
    FIXTURE_RED_PROOF='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ssh box \"hostname\""},"agent_type":"","agent_id":"a"}'
    pre_fix_stdout=$(printf '%s' "$FIXTURE_RED_PROOF" |
        env CLAUDE_ROLE=ops bash "$PRE_FIX_GUARD" 2>/dev/null || true)
    if printf '%s' "$pre_fix_stdout" | grep -q '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"'; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS (RED): pre-fix body denies ops non-git Bash (bug confirmed)\n'
        pass=$((pass + 1))
    else
        printf 'FAIL (RED): pre-fix body did NOT deny ops non-git Bash — RED proof invalid, bug may already be fixed at HEAD\n'
        fail=$((fail + 1))
    fi
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

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
