#!/bin/bash
# developer-no-self-gate_test.sh — unit tests for developer-no-self-gate.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/developer-no-self-gate.sh"

pass=0
fail=0

assert_contains() {
    local desc="$1"
    local needle="$2"
    local haystack="$3"
    if printf '%s' "$haystack" | grep -qF "$needle"; then
        printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s\n  needle: %s\n  haystack: %s\n' "$desc" "$needle" "$haystack"
        fail=$((fail + 1))
    fi
}

assert_not_contains() {
    local desc="$1"
    local needle="$2"
    local haystack="$3"
    if printf '%s' "$haystack" | grep -qF "$needle"; then
        printf 'FAIL: %s\n  unexpected: %s\n  haystack: %s\n' "$desc" "$needle" "$haystack"
        fail=$((fail + 1))
    else
        printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    fi
}

make_input() {
    local cmd="$1"
    local agent="${2:-developer-phoenix-backend}"
    local sid="${3:-test-session-$$}"
    jq -n \
        --arg cmd "$cmd" \
        --arg agent "$agent" \
        --arg sid "$sid" \
        '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":$cmd},"agent_type":$agent,"agent_id":"abc","session_id":$sid}'
}

# ── Test 1: non-developer agent → ALLOW ──────────────────────────────────────
SID1="sid1-$$-$(date -u +%s)"
rm -f "/tmp/combobulate-self-gate-${SID1}.count"
out=$(make_input "mix test test/foo_test.exs" "reviewer-phoenix" "$SID1" | bash "$HOOK" 2>/dev/null || true)
assert_not_contains "non-developer ALLOWED" '"permissionDecision"' "$out"
rm -f "/tmp/combobulate-self-gate-${SID1}.count"

# ── Test 2: non-CI command → ALLOW ───────────────────────────────────────────
SID2="sid2-$$-$(date -u +%s)"
rm -f "/tmp/combobulate-self-gate-${SID2}.count"
out=$(make_input "mix deps.get" "developer-phoenix-backend" "$SID2" | bash "$HOOK" 2>/dev/null || true)
assert_not_contains "non-CI command ALLOWED" '"permissionDecision"' "$out"
rm -f "/tmp/combobulate-self-gate-${SID2}.count"

# ── Test 3: 1st CI invocation → ALLOW (count=1) ──────────────────────────────
SID3="sid3-$$-$(date -u +%s)"
rm -f "/tmp/combobulate-self-gate-${SID3}.count"
out=$(make_input "mix test test/foo_test.exs" "developer-phoenix-backend" "$SID3" | bash "$HOOK" 2>/dev/null || true)
assert_not_contains "1st CI invocation (count=1) ALLOWED" '"permissionDecision"' "$out"
count=$(cat "/tmp/combobulate-self-gate-${SID3}.count" 2>/dev/null || echo 0)
[ "$count" = "1" ] && { printf 'PASS: counter incremented to 1\n'; pass=$((pass + 1)); } || { printf 'FAIL: counter expected 1, got %s\n' "$count"; fail=$((fail + 1)); }
rm -f "/tmp/combobulate-self-gate-${SID3}.count"

# ── Test 4: 3rd CI invocation → BLOCK ────────────────────────────────────────
SID4="sid4-$$-$(date -u +%s)"
printf '2' >"/tmp/combobulate-self-gate-${SID4}.count"
out=$(make_input "make ci" "developer-phoenix-frontend" "$SID4" | bash "$HOOK" 2>/dev/null || true)
assert_contains "3rd CI invocation BLOCKED" '"permissionDecision"' "$out"
assert_contains "3rd CI block mentions dev-gate handoff" 'dev-gate.sh handoff' "$out"
rm -f "/tmp/combobulate-self-gate-${SID4}.count"

# ── Test 5: make ci-fast pattern matched ─────────────────────────────────────
SID5="sid5-$$-$(date -u +%s)"
printf '2' >"/tmp/combobulate-self-gate-${SID5}.count"
out=$(make_input "make ci-fast" "developer-html" "$SID5" | bash "$HOOK" 2>/dev/null || true)
assert_contains "make ci-fast at count=3 BLOCKED" '"permissionDecision"' "$out"
rm -f "/tmp/combobulate-self-gate-${SID5}.count"

# ── Test 6: mix credo pattern matched ────────────────────────────────────────
SID6="sid6-$$-$(date -u +%s)"
printf '2' >"/tmp/combobulate-self-gate-${SID6}.count"
out=$(make_input "mix credo --strict" "developer-phoenix-backend" "$SID6" | bash "$HOOK" 2>/dev/null || true)
assert_contains "mix credo at count=3 BLOCKED" '"permissionDecision"' "$out"
rm -f "/tmp/combobulate-self-gate-${SID6}.count"

# ── Test 7: developer-vite also gated ────────────────────────────────────────
SID7="sid7-$$-$(date -u +%s)"
printf '2' >"/tmp/combobulate-self-gate-${SID7}.count"
out=$(make_input "make test" "developer-vite" "$SID7" | bash "$HOOK" 2>/dev/null || true)
assert_contains "developer-vite at count=3 BLOCKED" '"permissionDecision"' "$out"
rm -f "/tmp/combobulate-self-gate-${SID7}.count"

# ── Test 8: mix format matched ───────────────────────────────────────────────
SID8="sid8-$$-$(date -u +%s)"
printf '2' >"/tmp/combobulate-self-gate-${SID8}.count"
out=$(make_input "mix format --check-formatted" "developer-phoenix-backend" "$SID8" | bash "$HOOK" 2>/dev/null || true)
assert_contains "mix format at count=3 BLOCKED" '"permissionDecision"' "$out"
rm -f "/tmp/combobulate-self-gate-${SID8}.count"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
