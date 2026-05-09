#!/bin/bash
# build-worker-cwd-guard_test.sh — unit tests for build-worker-cwd-guard.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/build-worker-cwd-guard.sh"

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

# Use a user-app-like cwd so the guard engages (guard is a no-op outside real apps_root).
# mktemp gives us a real dir; we embed it under a synthetic */AppBuilder/apps/ path.
BASE_TMP="$(mktemp -d)"
PROJECT_DIR="${BASE_TMP}/AppBuilder/apps/abc123"
mkdir -p "$PROJECT_DIR"
cleanup() { rm -rf "$BASE_TMP"; }
trap cleanup EXIT

# Test 1: Orchestrator Read of /etc/passwd (outside project dir, user-app cwd) — BLOCK
FIXTURE_BLOCK_ETC='{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"/etc/passwd"},"agent_id":"","agent_type":"","cwd":"'"$PROJECT_DIR"'"}'
run_test "orchestrator Read /etc/passwd in user-app cwd blocks" "2" "$FIXTURE_BLOCK_ETC"

# Test 2: Subagent Read of /etc/passwd — ALLOW (escape hatch)
FIXTURE_SUBAGENT_ETC='{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"/etc/passwd"},"agent_id":"abc123","agent_type":"planner","cwd":"'"$PROJECT_DIR"'"}'
run_test "subagent Read /etc/passwd allows (escape hatch)" "0" "$FIXTURE_SUBAGENT_ETC"

# Test 3: Orchestrator Read of project file — ALLOW
PROJECT_FILE="$PROJECT_DIR/lib/foo.ex"
mkdir -p "$(dirname "$PROJECT_FILE")"
touch "$PROJECT_FILE"
FIXTURE_ALLOW_PROJECT='{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"'"$PROJECT_FILE"'"},"agent_id":"","agent_type":"","cwd":"'"$PROJECT_DIR"'"}'
run_test "orchestrator Read project file allows" "0" "$FIXTURE_ALLOW_PROJECT"

# Test 4: Orchestrator Bash with cd /tmp — ALLOW (whitelist)
FIXTURE_ALLOW_TMP='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"cd /tmp && ls"},"agent_id":"","agent_type":"","cwd":"'"$PROJECT_DIR"'"}'
run_test "orchestrator Bash cd /tmp allows (whitelist)" "0" "$FIXTURE_ALLOW_TMP"

# Test 5: Orchestrator Bash with /etc reference — BLOCK
FIXTURE_BLOCK_BASH='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"cat /etc/hosts"},"agent_id":"","agent_type":"","cwd":"'"$PROJECT_DIR"'"}'
run_test "orchestrator Bash /etc/hosts blocks" "2" "$FIXTURE_BLOCK_BASH"

# Test 6: Orchestrator Read of /etc/passwd in platform repo (non-apps_root cwd) — ALLOW
# The guard is a no-op when cwd is not under a real apps_root path.
PLATFORM_DIR="/Users/almirsarajcic/Projects/AppBuilder/combobulate"
FIXTURE_PLATFORM_READ='{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"/etc/passwd"},"agent_id":"","agent_type":"","cwd":"'"$PLATFORM_DIR"'"}'
run_test "orchestrator Read in platform repo (non-apps_root cwd) allows" "0" "$FIXTURE_PLATFORM_READ"

# Test 7: Orchestrator Read of file outside project in user-app cwd — BLOCK
USER_APP_DIR="/home/combobulate/apps/abc123"
FIXTURE_USER_APP_BLOCK='{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"/etc/passwd"},"agent_id":"","agent_type":"","cwd":"'"$USER_APP_DIR"'"}'
run_test "orchestrator Read /etc/passwd in user-app cwd blocks" "2" "$FIXTURE_USER_APP_BLOCK"

# Test 8: Orchestrator Read of /etc/passwd in test-partition cwd — BLOCK
TEST_APPS_DIR="${BASE_TMP}/.combobulate_test_apps/part1/apps/abc123"
mkdir -p "$TEST_APPS_DIR"
FIXTURE_TEST_APPS_BLOCK='{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"/etc/passwd"},"agent_id":"","agent_type":"","cwd":"'"$TEST_APPS_DIR"'"}'
run_test "orchestrator Read /etc/passwd in test-partition cwd blocks" "2" "$FIXTURE_TEST_APPS_BLOCK"

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
