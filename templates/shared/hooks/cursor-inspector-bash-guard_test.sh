#!/bin/bash
# cursor-inspector-bash-guard_test.sh — unit tests for cursor-inspector-bash-guard.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/cursor-inspector-bash-guard.sh"

pass=0
fail=0

TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

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

# Test 1: git log — ALLOW (cwd from stdin JSON)
FIXTURE_GIT_LOG='{"cwd":"'"$TMP_DIR"'","command":"git log --oneline"}'
run_test "git log with cwd in stdin allows" "0" "$FIXTURE_GIT_LOG"

# Test 2: redirect-overwrite — BLOCK
FIXTURE_REDIRECT='{"cwd":"'"$TMP_DIR"'","command":"echo foo > bar.txt"}'
run_test "redirect-overwrite blocks" "2" "$FIXTURE_REDIRECT"

# Test 3: rm — BLOCK
FIXTURE_RM='{"cwd":"'"$TMP_DIR"'","command":"rm foo.txt"}'
run_test "rm blocks" "2" "$FIXTURE_RM"

# Test 4: git commit — BLOCK
FIXTURE_GIT_COMMIT='{"cwd":"'"$TMP_DIR"'","command":"git commit -m \"fix\""}'
run_test "git commit blocks" "2" "$FIXTURE_GIT_COMMIT"

# Test 5: cat /etc/passwd — BLOCK (outside cwd from stdin)
FIXTURE_CAT_PASSWD='{"cwd":"'"$TMP_DIR"'","command":"cat /etc/passwd"}'
run_test "cat /etc/passwd blocks" "2" "$FIXTURE_CAT_PASSWD"

# Test 6: empty cwd falls back to $PWD — git log ALLOW
FIXTURE_EMPTY_CWD='{"command":"git log --oneline"}'
run_test "empty cwd falls back to PWD, git log allows" "0" "$FIXTURE_EMPTY_CWD"

# Test 7: psql DELETE — BLOCK
FIXTURE_PSQL='{"cwd":"'"$TMP_DIR"'","command":"psql -c \"DELETE FROM users\""}'
run_test "psql DELETE blocks" "2" "$FIXTURE_PSQL"

# Test 8: grep inside project — ALLOW
FIXTURE_GREP='{"cwd":"'"$TMP_DIR"'","command":"grep -r DELETE '"$TMP_DIR"'/lib/"}'
run_test "grep inside project allows" "0" "$FIXTURE_GREP"

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
