#!/bin/bash
# claude-inspector-read-guard_test.sh — unit tests for claude-inspector-read-guard.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/claude-inspector-read-guard.sh"

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
    local project_dir="${4:-/tmp}"
    local stdout
    stdout=$(
        export CLAUDE_PROJECT_DIR="$project_dir"
        printf '%s' "$input" | bash "$GUARD" 2>/dev/null || true
    )

    local outcome
    if printf '%s' "$stdout" | grep -q '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"'; then
        outcome="2"
    else
        outcome="0"
    fi

    if [ "$outcome" = "$expected" ]; then
        printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s — expected %s (deny=2/allow=0), got %s\n  stdout: %s\n' "$desc" "$expected" "$outcome" "$stdout"
        fail=$((fail + 1))
    fi
}

TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

# Test 1: Read within project dir — ALLOW (inspector context via JSON)
PROJ_FILE="$TMP_DIR/lib/foo.ex"
mkdir -p "$(dirname "$PROJ_FILE")"
touch "$PROJ_FILE"
FIXTURE_IN='{"hook_event_name":"PreToolUse","agent_type":"inspector","tool_name":"Read","tool_input":{"file_path":"'"$PROJ_FILE"'"}}'
run_test "Read within project dir allows" "0" "$FIXTURE_IN" "$TMP_DIR"

# Test 2: Read outside project dir — BLOCK (inspector context via JSON)
FIXTURE_OUT='{"hook_event_name":"PreToolUse","agent_type":"inspector","tool_name":"Read","tool_input":{"file_path":"/etc/passwd"}}'
run_test "Read outside project dir blocks" "2" "$FIXTURE_OUT" "$TMP_DIR"

# Test 3: Bash tool — ALLOW (not a Read tool)
FIXTURE_BASH='{"hook_event_name":"PreToolUse","agent_type":"inspector","tool_name":"Bash","tool_input":{"command":"ls"}}'
run_test "Bash tool allowed" "0" "$FIXTURE_BASH" "$TMP_DIR"

# Test 4: Read with .. traversal — BLOCK (inspector context via JSON)
FIXTURE_DOTDOT='{"hook_event_name":"PreToolUse","agent_type":"inspector","tool_name":"Read","tool_input":{"file_path":"'"$TMP_DIR/../../../etc/passwd"'"}}'
run_test "Read with .. traversal blocks" "2" "$FIXTURE_DOTDOT" "$TMP_DIR"

# Test 5: No agent_type in JSON (outer session) — ALLOW (early exit)
FIXTURE_OUTER='{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"/etc/passwd"}}'
result_outer=$(
    export CLAUDE_PROJECT_DIR="$TMP_DIR"
    printf '%s' "$FIXTURE_OUTER" | bash "$GUARD" 2>/dev/null || true
)
if printf '%s' "$result_outer" | grep -q '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"'; then
    printf 'FAIL: outer-session Read should allow (early exit) but got deny\n'
    fail=$((fail + 1))
else
    printf 'PASS: outer-session Read allows (early exit)\n'
    pass=$((pass + 1))
fi

# Test 6: agent_type is a non-inspector value — ALLOW (early exit)
FIXTURE_DEVAGENT='{"hook_event_name":"PreToolUse","agent_type":"developer-phoenix-backend","tool_name":"Read","tool_input":{"file_path":"/etc/passwd"}}'
result_dev=$(
    export CLAUDE_PROJECT_DIR="$TMP_DIR"
    printf '%s' "$FIXTURE_DEVAGENT" | bash "$GUARD" 2>/dev/null || true
)
if printf '%s' "$result_dev" | grep -q '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"'; then
    printf 'FAIL: developer-phoenix-backend Read should allow (early exit) but got deny\n'
    fail=$((fail + 1))
else
    printf 'PASS: developer-phoenix-backend Read allows (early exit)\n'
    pass=$((pass + 1))
fi

# Test 7: agent_type=inspector, file outside project — BLOCK (guard applies)
FIXTURE_INSPECTOR_OUTSIDE='{"hook_event_name":"PreToolUse","agent_type":"inspector","tool_name":"Read","tool_input":{"file_path":"/etc/passwd"}}'
result_inspector=$(
    export CLAUDE_PROJECT_DIR="$TMP_DIR"
    printf '%s' "$FIXTURE_INSPECTOR_OUTSIDE" | bash "$GUARD" 2>/dev/null || true
)
if printf '%s' "$result_inspector" | grep -q '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"'; then
    printf 'PASS: inspector Read outside project dir blocks\n'
    pass=$((pass + 1))
else
    printf 'FAIL: inspector Read outside project dir should block but got allow\n  stdout: %s\n' "$result_inspector"
    fail=$((fail + 1))
fi

echo ""
echo "Results: $pass passed, $fail failed"

[ "$fail" -gt 0 ] && exit 1
exit 0
