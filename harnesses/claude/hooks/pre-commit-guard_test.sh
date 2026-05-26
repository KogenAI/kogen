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
        printf 'PASS: %s
' "$desc"
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
        printf 'PASS: %s
' "$desc"
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

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
