#!/bin/bash
# codex-inspector-bash-guard_test.sh — unit tests for codex-inspector-bash-guard.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/codex-inspector-bash-guard.sh"

pass=0
fail=0

TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

run_test() {
    local desc="$1"
    local expected="$2"
    local input="$3"
    local project_dir="${4:-$TMP_DIR}"

    actual_code=$(
        export CODEX_PROJECT_DIR="$project_dir"
        printf '%s' "$input" | bash "$GUARD" 2>/dev/null
        echo $?
    )

    if [ "$actual_code" = "$expected" ]; then
        printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s — expected exit %s, got %s\n' "$desc" "$expected" "$actual_code"
        fail=$((fail + 1))
    fi
}

# Test 1: non-shell tool — ALLOW (early exit)
FIXTURE_OTHER='{"hook_event_name":"PreToolUse","tool_name":"apply_patch","tool_input":{"patch":"---"}}'
run_test "non-shell tool allows" "0" "$FIXTURE_OTHER"

# Test 2: git log — ALLOW
FIXTURE_GIT_LOG='{"hook_event_name":"PreToolUse","tool_name":"shell","tool_input":{"command":"git log --oneline"}}'
run_test "git log allows" "0" "$FIXTURE_GIT_LOG"

# Test 3: redirect-overwrite — BLOCK
FIXTURE_REDIRECT='{"hook_event_name":"PreToolUse","tool_name":"shell","tool_input":{"command":"echo foo > bar.txt"}}'
run_test "redirect-overwrite blocks" "2" "$FIXTURE_REDIRECT"

# Test 4: append-redirect >> — BLOCK
FIXTURE_APPEND='{"hook_event_name":"PreToolUse","tool_name":"shell","tool_input":{"command":"echo foo >> bar.txt"}}'
run_test "append-redirect blocks" "2" "$FIXTURE_APPEND"

# Test 5: rm — BLOCK
FIXTURE_RM='{"hook_event_name":"PreToolUse","tool_name":"local_shell","tool_input":{"command":"rm foo.txt"}}'
run_test "rm blocks" "2" "$FIXTURE_RM"

# Test 6: git commit — BLOCK
FIXTURE_GIT_COMMIT='{"hook_event_name":"PreToolUse","tool_name":"shell","tool_input":{"command":"git commit -m \"fix\""}}'
run_test "git commit blocks" "2" "$FIXTURE_GIT_COMMIT"

# Test 7: psql with DELETE — BLOCK
FIXTURE_PSQL='{"hook_event_name":"PreToolUse","tool_name":"shell","tool_input":{"command":"psql -c \"DELETE FROM users\""}}'
run_test "psql DELETE blocks" "2" "$FIXTURE_PSQL"

# Test 8: grep DELETE in source — ALLOW
FIXTURE_GREP='{"hook_event_name":"PreToolUse","tool_name":"shell","tool_input":{"command":"grep DELETE module.ex"}}'
run_test "grep DELETE allows" "0" "$FIXTURE_GREP"

# Test 9: cat /etc/passwd — BLOCK (outside project dir)
FIXTURE_CAT_PASSWD='{"hook_event_name":"PreToolUse","tool_name":"shell","tool_input":{"command":"cat /etc/passwd"}}'
run_test "cat /etc/passwd blocks" "2" "$FIXTURE_CAT_PASSWD"

# Test 10: cat inside project dir — ALLOW
FIXTURE_CAT_PROJECT='{"hook_event_name":"PreToolUse","tool_name":"shell","tool_input":{"command":"cat '"$TMP_DIR"'/lib/x.ex"}}'
run_test "cat inside project dir allows" "0" "$FIXTURE_CAT_PROJECT"

# Test 11: sed -i — BLOCK
FIXTURE_SED_I='{"hook_event_name":"PreToolUse","tool_name":"shell","tool_input":{"command":"sed -i s/foo/bar/g file.txt"}}'
run_test "sed -i blocks" "2" "$FIXTURE_SED_I"

# Test 12: 2>/dev/null — ALLOW
FIXTURE_DEVNULL='{"hook_event_name":"PreToolUse","tool_name":"shell","tool_input":{"command":"git status 2>/dev/null"}}'
run_test "2>/dev/null allows" "0" "$FIXTURE_DEVNULL"

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
