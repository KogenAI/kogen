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
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
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
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
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
rm -f "/tmp/codegen-self-gate-${SID1}.count"
out=$(make_input "mix test test/foo_test.exs" "reviewer-phoenix" "$SID1" | bash "$HOOK" 2>/dev/null || true)
assert_not_contains "non-developer ALLOWED" '"permissionDecision"' "$out"
rm -f "/tmp/codegen-self-gate-${SID1}.count"

# ── Test 2: non-CI command → ALLOW ───────────────────────────────────────────
SID2="sid2-$$-$(date -u +%s)"
rm -f "/tmp/codegen-self-gate-${SID2}.count"
out=$(make_input "mix deps.get" "developer-phoenix-backend" "$SID2" | bash "$HOOK" 2>/dev/null || true)
assert_not_contains "non-CI command ALLOWED" '"permissionDecision"' "$out"
rm -f "/tmp/codegen-self-gate-${SID2}.count"

# ── Test 3: 1st CI invocation → ALLOW (count=1) ──────────────────────────────
SID3="sid3-$$-$(date -u +%s)"
rm -f "/tmp/codegen-self-gate-${SID3}.count"
out=$(make_input "mix test test/foo_test.exs" "developer-phoenix-backend" "$SID3" | bash "$HOOK" 2>/dev/null || true)
assert_not_contains "1st CI invocation (count=1) ALLOWED" '"permissionDecision"' "$out"
count=$(cat "/tmp/codegen-self-gate-${SID3}.count" 2>/dev/null || echo 0)
[ "$count" = "1" ] && {
    [ -n "${VERBOSE:-}" ] && printf 'PASS: counter incremented to 1\n'
    pass=$((pass + 1))
} || {
    printf 'FAIL: counter expected 1, got %s\n' "$count"
    fail=$((fail + 1))
}
rm -f "/tmp/codegen-self-gate-${SID3}.count"

# ── Test 4: 3rd CI invocation → BLOCK ────────────────────────────────────────
SID4="sid4-$$-$(date -u +%s)"
printf '2' >"/tmp/codegen-self-gate-${SID4}.count"
out=$(make_input "make ci" "developer-phoenix-frontend" "$SID4" | bash "$HOOK" 2>/dev/null || true)
assert_contains "3rd CI invocation BLOCKED" '"permissionDecision"' "$out"
assert_contains "3rd CI block mentions dev-gate handoff" 'dev-gate.sh handoff' "$out"
rm -f "/tmp/codegen-self-gate-${SID4}.count"

# ── Test 5: make ci pattern matched ──────────────────────────────────────────
SID5="sid5-$$-$(date -u +%s)"
printf '2' >"/tmp/codegen-self-gate-${SID5}.count"
out=$(make_input "make ci" "developer-static" "$SID5" | bash "$HOOK" 2>/dev/null || true)
assert_contains "make ci at count=3 BLOCKED" '"permissionDecision"' "$out"
rm -f "/tmp/codegen-self-gate-${SID5}.count"

# ── Test 6: mix credo bypasses cap — ALWAYS ALLOWED ─────────────────────────
# mix credo is cheap/required before handoff; cap does not apply.
SID6="sid6-$$-$(date -u +%s)"
printf '2' >"/tmp/codegen-self-gate-${SID6}.count"
out=$(make_input "mix credo --strict" "developer-phoenix-backend" "$SID6" | bash "$HOOK" 2>/dev/null || true)
assert_not_contains "mix credo at count=3 STILL ALLOWED (bypasses cap)" '"permissionDecision"' "$out"
rm -f "/tmp/codegen-self-gate-${SID6}.count"

# ── Test 6b: mix credo bypasses cap even at count=10 ────────────────────────
SID6B="sid6b-$$-$(date -u +%s)"
printf '10' >"/tmp/codegen-self-gate-${SID6B}.count"
out=$(make_input "mix credo --strict path/to/file.ex" "developer-phoenix-backend" "$SID6B" | bash "$HOOK" 2>/dev/null || true)
assert_not_contains "mix credo scoped at count=10 STILL ALLOWED" '"permissionDecision"' "$out"
rm -f "/tmp/codegen-self-gate-${SID6B}.count"

# ── Test 6c: make ci IS still blocked after 3 calls ─────────────────────────
SID6C="sid6c-$$-$(date -u +%s)"
printf '2' >"/tmp/codegen-self-gate-${SID6C}.count"
out=$(make_input "make ci" "developer-phoenix-backend" "$SID6C" | bash "$HOOK" 2>/dev/null || true)
assert_contains "make ci at count=3 BLOCKED (cap still applies)" '"permissionDecision"' "$out"
rm -f "/tmp/codegen-self-gate-${SID6C}.count"

# ── Test 7: developer-static also gated ──────────────────────────────────────
SID7="sid7-$$-$(date -u +%s)"
printf '2' >"/tmp/codegen-self-gate-${SID7}.count"
out=$(make_input "make test" "developer-static" "$SID7" | bash "$HOOK" 2>/dev/null || true)
assert_contains "developer-static at count=3 BLOCKED" '"permissionDecision"' "$out"
rm -f "/tmp/codegen-self-gate-${SID7}.count"

# ── Test 8: mix format matched ───────────────────────────────────────────────
SID8="sid8-$$-$(date -u +%s)"
printf '2' >"/tmp/codegen-self-gate-${SID8}.count"
out=$(make_input "mix format --check-formatted" "developer-phoenix-backend" "$SID8" | bash "$HOOK" 2>/dev/null || true)
assert_contains "mix format at count=3 BLOCKED" '"permissionDecision"' "$out"
rm -f "/tmp/codegen-self-gate-${SID8}.count"

# ── Test 9: codegen-log write narrating "make ci" in heredoc body → ALLOW, no counter bump ──
SID9="sid9-$$-$(date -u +%s)"
rm -f "/tmp/codegen-self-gate-${SID9}.count"
LOG_CMD='codegen-log section --slug test --body @- <<'"'"'EOF'"'"'
## developer-phoenix-backend Section
Ran make ci and mix test three times, all green.
EOF'
out=$(make_input "$LOG_CMD" "developer-phoenix-backend" "$SID9" | bash "$HOOK" 2>/dev/null || true)
assert_not_contains "codegen-log write narrating gated phrase ALLOWED" '"permissionDecision"' "$out"
if [ -f "/tmp/codegen-self-gate-${SID9}.count" ]; then
    printf 'FAIL: codegen-log write must NOT create/increment counter file\n'
    fail=$((fail + 1))
else
    [ -n "${VERBOSE:-}" ] && printf 'PASS: codegen-log write did not touch counter file\n'
    pass=$((pass + 1))
fi
rm -f "/tmp/codegen-self-gate-${SID9}.count"

# ── Test 10: real standalone make ci still denies/counts unchanged at count=3 ──
SID10="sid10-$$-$(date -u +%s)"
printf '2' >"/tmp/codegen-self-gate-${SID10}.count"
out=$(make_input "make ci" "developer-phoenix-backend" "$SID10" | bash "$HOOK" 2>/dev/null || true)
assert_contains "real make ci at count=3 STILL BLOCKED" '"permissionDecision"' "$out"
rm -f "/tmp/codegen-self-gate-${SID10}.count"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
