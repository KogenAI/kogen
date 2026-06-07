#!/bin/bash
# env-var-sample-consistency_test.sh — unit tests for env-var-sample-consistency.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/env-var-sample-consistency.sh"

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
    local test_dir="${4:-}"
    local stdout
    if [ -n "$test_dir" ]; then
        stdout=$(cd "$test_dir" && printf '%s' "$input" | bash "$GUARD" 2>/dev/null || true)
    else
        stdout=$(printf '%s' "$input" | bash "$GUARD" 2>/dev/null || true)
    fi

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

# Set up a tmp git repo for realistic staging tests
TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

(
    cd "$TMP_DIR"
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test"
    # Create runtime.exs with System.get_env
    printf 'config :app, key: System.get_env("EXISTING_VAR")\n' >runtime.exs
    printf 'export EXISTING_VAR=\n' >.env.sample
    printf 'EXISTING_VAR=\n' >.env.prod.sample
    git add runtime.exs .env.sample .env.prod.sample
    git commit -q -m "init"
)

# Test 1: Non-committer — not gated by this hook
FIXTURE_NON_COMMITTER='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git commit -m \"test\""},"agent_type":"developer-phoenix-backend","agent_id":"abc"}'
run_test "non-committer is not gated" "0" "$FIXTURE_NON_COMMITTER" "$TMP_DIR"

# Test 2: Committer with non-env staged files — ALLOW
(
    cd "$TMP_DIR"
    printf 'Some markdown\n' >README.md
    git add README.md
)
FIXTURE_NO_ENV='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git commit -m \"Add readme\""},"agent_type":"committer","agent_id":"abc"}'
run_test "committer with non-env diff allows" "0" "$FIXTURE_NO_ENV" "$TMP_DIR"
(cd "$TMP_DIR" && git reset HEAD README.md 2>/dev/null || true)

# Test 3: Committer with env-var changes but no sample files — BLOCK
(
    cd "$TMP_DIR"
    printf 'config :app, key: System.get_env("NEW_VAR")\n' >runtime.exs
    git add runtime.exs
)
FIXTURE_NO_SAMPLE='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git commit -m \"Add env var\""},"agent_type":"committer","agent_id":"abc"}'
run_test "committer with env-var diff but no samples blocks" "2" "$FIXTURE_NO_SAMPLE" "$TMP_DIR"

# Test 4: Committer with env-var changes AND both sample files — ALLOW
(
    cd "$TMP_DIR"
    printf 'export NEW_VAR=\n' >>.env.sample
    printf 'NEW_VAR=\n' >>.env.prod.sample
    git add .env.sample .env.prod.sample
)
FIXTURE_WITH_SAMPLES='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git commit -m \"Add env var with samples\""},"agent_type":"committer","agent_id":"abc"}'
run_test "committer with env-var diff and both samples allows" "0" "$FIXTURE_WITH_SAMPLES" "$TMP_DIR"
# Clean up staged changes
(cd "$TMP_DIR" && git reset HEAD 2>/dev/null || true)

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
