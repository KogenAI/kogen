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
# Clean up staged changes AND revert sample content back to the committed
# baseline (NEW_VAR must be undeclared again for Test 6's re-check of the
# no-samples-staged scenario — unstaging alone leaves NEW_VAR= in the
# working-tree .env.sample, which would falsely satisfy the new
# not-already-declared predicate).
(
    cd "$TMP_DIR" && git reset HEAD 2>/dev/null || true
    git checkout -- .env.sample .env.prod.sample 2>/dev/null || true
)

# Test 5: codegen-log write narrating env-var commit without samples staged — ALLOW
(
    cd "$TMP_DIR"
    printf 'config :app, key: System.get_env("NEW_VAR")\n' >runtime.exs
    git add runtime.exs
)
FIXTURE_LOG_WRITE=$(jq -n \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"codegen-log section --slug test --body @- <<EOF\n## committer Section\nRan git commit -m \"Add env var\" — denied as expected (missing samples).\nEOF"},"agent_type":"committer","agent_id":"abc"}')
run_test "codegen-log write narrating missing-samples commit ALLOWED" "0" "$FIXTURE_LOG_WRITE" "$TMP_DIR"

# Test 6: real standalone commit with same staged diff still BLOCKED unchanged
run_test "real env-var commit without samples still blocks (unchanged)" "2" "$FIXTURE_NO_SAMPLE" "$TMP_DIR"
(cd "$TMP_DIR" && git reset HEAD 2>/dev/null || true)

# Test 7: argless System.get_env() (no literal arg) — no lookup possible, ALLOW
(
    cd "$TMP_DIR"
    printf 'config :app, key: System.get_env()\n' >runtime.exs
    git add runtime.exs
)
FIXTURE_ARGLESS='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git commit -m \"argless env read\""},"agent_type":"committer","agent_id":"abc"}'
run_test "argless System.get_env() with no samples staged allows" "0" "$FIXTURE_ARGLESS" "$TMP_DIR"
(
    cd "$TMP_DIR" && git reset HEAD 2>/dev/null || true
    git checkout -- runtime.exs 2>/dev/null || true
)

# Test 8: literal var already declared in .env.sample (EXISTING_VAR) — ALLOW
(
    cd "$TMP_DIR"
    printf 'config :app, key: System.get_env("EXISTING_VAR")\nconfig :app, other: 1\n' >runtime.exs
    git add runtime.exs
)
FIXTURE_DOCUMENTED='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git commit -m \"read documented var\""},"agent_type":"committer","agent_id":"abc"}'
run_test "already-documented literal var read allows" "0" "$FIXTURE_DOCUMENTED" "$TMP_DIR"
(
    cd "$TMP_DIR" && git reset HEAD 2>/dev/null || true
    git checkout -- runtime.exs 2>/dev/null || true
)

# Test 9: diff only REMOVES a System.get_env("GONE_VAR") line (no additions) — ALLOW
(
    cd "$TMP_DIR"
    printf 'config :app, key: System.get_env("GONE_VAR")\n' >runtime.exs
    git add runtime.exs
    git commit -q -m "add gone var read"
    printf '' >runtime.exs
    git add runtime.exs
)
FIXTURE_REMOVED_ONLY='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git commit -m \"remove env var read\""},"agent_type":"committer","agent_id":"abc"}'
run_test "removed-only System.get_env line allows (added-only unification)" "0" "$FIXTURE_REMOVED_ONLY" "$TMP_DIR"
(
    cd "$TMP_DIR"
    git reset HEAD 2>/dev/null || true
    git reset --hard HEAD~1 -q 2>/dev/null || true
)

# Test 10: new underscore/digit literal var name, absent from sample — BLOCK
# (regression guard on the name-extraction regex)
(
    cd "$TMP_DIR"
    printf 'config :app, key: System.get_env("CODEGEN_BUILD_NEW1")\n' >runtime.exs
    git add runtime.exs
)
FIXTURE_UNDERSCORE_DIGIT='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git commit -m \"add underscore/digit var\""},"agent_type":"committer","agent_id":"abc"}'
run_test "new underscore/digit literal var name blocks" "2" "$FIXTURE_UNDERSCORE_DIGIT" "$TMP_DIR"
(
    cd "$TMP_DIR" && git reset HEAD 2>/dev/null || true
    git checkout -- runtime.exs 2>/dev/null || true
)

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
