#!/bin/bash
# post-developer-format_test.sh — unit tests for post-developer-format.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/post-developer-format.sh"

pass=0
fail=0

run_test() {
    local desc="$1"
    local expected="$2"
    local input="$3"

    actual_code=$(
        printf '%s' "$input" | bash "$HOOK" 2>/dev/null
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

# Test 1: non-developer agent_type exits 0 immediately (no-op)
FIXTURE_NOOP='{"hook_event_name":"SubagentStop","agent_type":"planner","agent_id":"abc","session_id":"s1","cwd":"/tmp","stop_hook_active":false}'
run_test "non-developer agent_type is no-op" "0" "$FIXTURE_NOOP"

# Test 2: stop_hook_active=true exits 0 immediately
FIXTURE_ACTIVE='{"hook_event_name":"SubagentStop","agent_type":"phoenix-developer","agent_id":"abc","session_id":"s1","cwd":"/tmp","stop_hook_active":true}'
run_test "stop_hook_active=true exits 0 immediately" "0" "$FIXTURE_ACTIVE"

# Test 3: phoenix-developer SubagentStop on git repo exits 0
TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

# Create a minimal git repo
(
    cd "$TMP_DIR"
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test"
    printf 'x = 1\n' >foo.ex
    git add foo.ex
    git commit -q -m "init"
) 2>/dev/null

# Now make a change
printf 'x = 2\n' >"$TMP_DIR/foo.ex"

FIXTURE_DEV='{"hook_event_name":"SubagentStop","agent_type":"phoenix-developer","agent_id":"abc","session_id":"s1","cwd":"'"$TMP_DIR"'","stop_hook_active":false}'
run_test "phoenix-developer on git repo exits 0" "0" "$FIXTURE_DEV"

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
