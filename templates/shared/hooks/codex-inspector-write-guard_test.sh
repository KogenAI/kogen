#!/bin/bash
# codex-inspector-write-guard_test.sh — unit tests for codex-inspector-write-guard.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/codex-inspector-write-guard.sh"

pass=0
fail=0

run_test() {
    local desc="$1"
    local expected="$2"
    local input="$3"
    # Use ${4+set} check: only default to "inspector" when arg 4 is UNSET (not when empty).
    # Passing "" explicitly means "no CODEX_ROLE" (simulate unset by exporting empty).
    local codex_role
    if [ "${4+set}" = "set" ]; then
        codex_role="$4"
    else
        codex_role="inspector"
    fi

    # Capture stdout — the hook now emits a permissionDecision JSON envelope
    # to stdout for deny outcomes (exit 0) instead of stderr + exit 2. We
    # translate the legacy expected values: "2" means "expect deny",
    # "0" means "expect allow (no deny envelope)".
    local stdout
    stdout=$(printf '%s' "$input" | CODEX_ROLE="$codex_role" bash "$GUARD" 2>/dev/null || true)

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

# Test 1: apply_patch — BLOCK (CODEX_ROLE=inspector)
FIXTURE_APPLY='{"hook_event_name":"PreToolUse","tool_name":"apply_patch","tool_input":{"patch":"--- a/file\n+++ b/file"}}'
run_test "apply_patch is blocked" "2" "$FIXTURE_APPLY" "inspector"

# Test 2: unrelated tool name — ALLOW
FIXTURE_SHELL='{"hook_event_name":"PreToolUse","tool_name":"shell","tool_input":{"command":"git log --oneline"}}'
run_test "shell tool is allowed" "0" "$FIXTURE_SHELL" "inspector"

# Test 3: empty tool name — ALLOW
FIXTURE_EMPTY='{"hook_event_name":"PreToolUse","tool_name":"","tool_input":{}}'
run_test "empty tool name is allowed" "0" "$FIXTURE_EMPTY" "inspector"

# Test 4: read-only tool — ALLOW
FIXTURE_READ='{"hook_event_name":"PreToolUse","tool_name":"read_file","tool_input":{"path":"/tmp/foo"}}'
run_test "read_file tool is allowed" "0" "$FIXTURE_READ" "inspector"

# Test 5: CODEX_ROLE unset — hook is no-op, apply_patch allowed (guard only fires for inspector)
FIXTURE_APPLY_NOOP='{"hook_event_name":"PreToolUse","tool_name":"apply_patch","tool_input":{"patch":"--- a/file\n+++ b/file"}}'
run_test "CODEX_ROLE unset — hook no-op, apply_patch allowed" "0" "$FIXTURE_APPLY_NOOP" ""

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
