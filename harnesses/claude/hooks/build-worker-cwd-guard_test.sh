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
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s — expected %s (deny=2/allow=0), got %s
  stdout: %s
' "$desc" "$expected" "$outcome" "$stdout"
        fail=$((fail + 1))
    fi
}

# Use a user-app-like cwd so the guard engages (guard is a no-op outside real apps_root).
# OCG_APPS_ROOT drives enforcement; PROJECT_DIR is a synthetic user-app under it.
BASE_TMP="$(mktemp -d)"
export OCG_APPS_ROOT="${BASE_TMP}/apps"
PROJECT_DIR="${OCG_APPS_ROOT}/abc123"
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

# Test 6: Orchestrator Read of /etc/passwd in platform repo (cwd outside OCG_APPS_ROOT) — ALLOW
# The guard is a no-op when cwd is not under OCG_APPS_ROOT.
PLATFORM_DIR="${BASE_TMP}/platform-repo"
mkdir -p "$PLATFORM_DIR"
FIXTURE_PLATFORM_READ='{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"/etc/passwd"},"agent_id":"","agent_type":"","cwd":"'"$PLATFORM_DIR"'"}'
run_test "orchestrator Read in platform repo (outside OCG_APPS_ROOT) allows" "0" "$FIXTURE_PLATFORM_READ"

# Test 7: Orchestrator Read of file outside project in user-app cwd (under OCG_APPS_ROOT) — BLOCK
USER_APP_DIR="${OCG_APPS_ROOT}/user-project-abc"
mkdir -p "$USER_APP_DIR"
FIXTURE_USER_APP_BLOCK='{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"/etc/passwd"},"agent_id":"","agent_type":"","cwd":"'"$USER_APP_DIR"'"}'
run_test "orchestrator Read /etc/passwd in user-app cwd (under OCG_APPS_ROOT) blocks" "2" "$FIXTURE_USER_APP_BLOCK"

# Test 8: Orchestrator Read of /etc/passwd with unset OCG_APPS_ROOT — ALLOW (unknown boundary)
# Use env -u to unset OCG_APPS_ROOT in the child process so the hook sees it as absent.
FIXTURE_UNSET_ROOT='{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"/etc/passwd"},"agent_id":"","agent_type":"","cwd":"'"$PROJECT_DIR"'"}'
stdout_t8=$(printf '%s' "$FIXTURE_UNSET_ROOT" | env -u OCG_APPS_ROOT bash "$GUARD" 2>/dev/null || true)
outcome_t8="0"
if printf '%s' "$stdout_t8" | grep -q '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"'; then
    outcome_t8="2"
fi
if [ "$outcome_t8" = "0" ]; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: orchestrator Read with unset OCG_APPS_ROOT allows (unknown boundary)\n'
    pass=$((pass + 1))
else
    printf 'FAIL: orchestrator Read with unset OCG_APPS_ROOT allows — expected 0, got %s\n  stdout: %s\n' "$outcome_t8" "$stdout_t8"
    fail=$((fail + 1))
fi

# Test 9: Orchestrator Bash with relative path traversal ../ — BLOCK
FIXTURE_TRAVERSAL='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"cat ../../../etc/passwd"},"agent_id":"","agent_type":"","cwd":"'"$PROJECT_DIR"'"}'
run_test "orchestrator Bash relative path traversal ../ blocks" "2" "$FIXTURE_TRAVERSAL"

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
