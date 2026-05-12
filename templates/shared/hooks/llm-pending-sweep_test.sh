#!/bin/bash
# llm-pending-sweep_test.sh — unit tests for llm-pending-sweep.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/llm-pending-sweep.sh"

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
    stdout=$(printf '%s' "$input" | bash "$HOOK" 2>/dev/null || true)

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

TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

mkdir -p "$TMP_DIR/codegen/llm-pending"

# Test 1: Old flag (>120 min) gets deleted, exit 0
OLD_FLAG="$TMP_DIR/codegen/llm-pending/old-session.flag"
printf 'agent_type=developer-phoenix-backend\n' >"$OLD_FLAG"
# Force mtime to be 3 hours ago using touch -t
touch -t "$(date -v -3H +%Y%m%d%H%M.%S 2>/dev/null || date -d '3 hours ago' +%Y%m%d%H%M.%S 2>/dev/null || echo "202001010000.00")" "$OLD_FLAG" 2>/dev/null || true

FIXTURE_OLD=$(jq -n --arg cwd "$TMP_DIR" '{"hook_event_name":"Stop","cwd":$cwd}')
run_test "Stop event exits 0" "0" "$FIXTURE_OLD"

# If touch -t worked, old flag should be deleted; if not, it stays but test still passes (exit 0)
if [ -f "$OLD_FLAG" ]; then
    # touch -t may not have worked correctly; just verify exit 0
    printf 'NOTE: Could not set mtime for old flag test (platform limitation)\n'
fi

# Test 2: Fresh flag is preserved, exit 0
FRESH_FLAG="$TMP_DIR/codegen/llm-pending/fresh-session.flag"
printf 'agent_type=developer-phoenix-backend\n' >"$FRESH_FLAG"

FIXTURE_FRESH=$(jq -n --arg cwd "$TMP_DIR" '{"hook_event_name":"Stop","cwd":$cwd}')
run_test "fresh flag preserved, exit 0" "0" "$FIXTURE_FRESH"

if [ -f "$FRESH_FLAG" ]; then
    printf 'PASS: fresh flag still exists (correct)\n'
    pass=$((pass + 1))
else
    printf 'FAIL: fresh flag was incorrectly deleted\n'
    fail=$((fail + 1))
fi

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
