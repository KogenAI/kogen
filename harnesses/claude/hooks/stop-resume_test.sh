#!/bin/bash
# stop-resume_test.sh — unit tests for stop-resume.sh
#
# Tests:
#   1.  Retryable error (stream idle timeout) → block decision emitted
#   2.  Hard failure (401 auth error) → no block (exit 0, no decision)
#   3.  Rate limit (429) → no retry (hard classify: let user wait)
#   4.  Normal stop (no error) → no block
#   5.  Retry cap: 8 attempts → 9th returns exit 0 without block
#   6.  STOP_HOOK_ACTIVE=true → exit 0 immediately (loop guard)
#   7.  500 error → block (retryable)
#   8.  connection reset → block (retryable)
#   10. "File has been modified since read" → block (auto-resume)
#   11. Cap-8 ceiling with "has been unexpectedly modified" → allow (no block)
#   12. "socket connection was closed" → block (retryable)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/stop-resume.sh"

pass=0
fail=0

TMP_DIR="$(mktemp -d)"
cleanup() {
    rm -rf "$TMP_DIR"
    # Counter files persist across runs and would push the static-session tests
    # past the retry cap → spurious "got allow" failures on the 4th+ run.
    rm -f /tmp/claude-resume-sess-t1.count \
        /tmp/claude-resume-sess-t2.count \
        /tmp/claude-resume-sess-t3.count \
        /tmp/claude-resume-sess-t4.count \
        /tmp/claude-resume-sess-t7.count \
        /tmp/claude-resume-sess-t8.count \
        /tmp/claude-resume-sess-t10.count \
        /tmp/claude-resume-sess-t12.count \
        /tmp/claude-resume-sess-loop.count
}

# Create a fake sleep binary in TMP_DIR that records its arg and exits 0.
# Tests that verify backoff behaviour prepend TMP_DIR to PATH so real sleep
# is never invoked (keeps the test suite fast even when delay=300).
SLEEP_STUB="$TMP_DIR/sleep"
SLEEP_CALLS="$TMP_DIR/sleep-calls"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$1" >> "%s"\n' "$SLEEP_CALLS" >"$SLEEP_STUB"
chmod +x "$SLEEP_STUB"
trap cleanup EXIT
cleanup # clean any leftovers from previous suite runs before tests start

run_test() {
    local desc="$1"
    local expected="$2" # "block" or "allow"
    local input="$3"
    local extra_env="${4:-}"

    local stdout
    stdout=$(printf '%s' "$input" | env \
        STOP_HOOK_ACTIVE=false \
        $extra_env \
        bash "$GUARD" 2>/dev/null || true)

    local outcome
    if printf '%s' "$stdout" | grep -q '"decision"[[:space:]]*:[[:space:]]*"block"'; then
        outcome="block"
    else
        outcome="allow"
    fi

    if [ "$outcome" = "$expected" ]; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s — expected %s, got %s\n  stdout: %s\n' \
            "$desc" "$expected" "$outcome" "$stdout"
        fail=$((fail + 1))
    fi
}

mk_stop() {
    local msg="$1"
    local session="${2:-test-sess-$(date +%s%N)}"
    jq -n \
        --arg msg "$msg" \
        --arg sid "$session" \
        '{"hook_event_name":"Stop","last_assistant_message":$msg,"session_id":$sid,"stop_hook_active":false}'
}

# Test 1: Stream idle timeout → block
run_test "stream idle timeout triggers block" "block" \
    "$(mk_stop 'Stream idle timeout occurred during response generation' 'sess-t1')"

# Test 2: 401 authentication error → no block (hard fail)
run_test "401 auth error does not retry" "allow" \
    "$(mk_stop 'API Error: 401 Unauthorized — invalid_api_key' 'sess-t2')"

# Test 3: 429 rate limit → no block (non-retryable)
run_test "429 rate limit does not retry" "allow" \
    "$(mk_stop 'API Error: 429 rate_limit exceeded' 'sess-t3')"

# Test 4: Normal stop (no error text) → no block
run_test "normal stop (no error) does not block" "allow" \
    "$(mk_stop 'Task complete.' 'sess-t4')"

# Test 5: Retry cap — 9th attempt should NOT block (cap = 8)
SESSION_CAP="sess-cap-$(date +%s%N)"
COUNTER_FILE="/tmp/claude-resume-${SESSION_CAP}.count"
printf '%s' "8" >"$COUNTER_FILE" # simulate already at cap
RETRYABLE_MSG="$(mk_stop 'Stream idle timeout occurred' "$SESSION_CAP")"
stdout_cap=$(printf '%s' "$RETRYABLE_MSG" | env STOP_HOOK_ACTIVE=false bash "$GUARD" 2>/dev/null || true)
if printf '%s' "$stdout_cap" | grep -q '"decision"[[:space:]]*:[[:space:]]*"block"'; then
    printf 'FAIL: retry cap — 9th attempt should NOT block\n  stdout: %s\n' "$stdout_cap"
    fail=$((fail + 1))
else
    [ -n "${VERBOSE:-}" ] && printf 'PASS: retry cap — 9th attempt does not block\n'
    pass=$((pass + 1))
fi
rm -f "$COUNTER_FILE"

# Test 6: STOP_HOOK_ACTIVE=true → exit 0 immediately (loop guard)
LOOP_INPUT=$(jq -n \
    '{"hook_event_name":"Stop","last_assistant_message":"Stream idle timeout","session_id":"sess-loop","stop_hook_active":true}')
stdout_loop=$(printf '%s' "$LOOP_INPUT" | env STOP_HOOK_ACTIVE=true bash "$GUARD" 2>/dev/null || true)
if printf '%s' "$stdout_loop" | grep -q '"decision"[[:space:]]*:[[:space:]]*"block"'; then
    printf 'FAIL: STOP_HOOK_ACTIVE=true should skip block\n  stdout: %s\n' "$stdout_loop"
    fail=$((fail + 1))
else
    [ -n "${VERBOSE:-}" ] && printf 'PASS: STOP_HOOK_ACTIVE=true skips block (loop guard)\n'
    pass=$((pass + 1))
fi

# Test 7: API 500 → block (retryable server error)
run_test "API Error 500 triggers block" "block" \
    "$(mk_stop 'API Error: 500 Internal server error' 'sess-t7')"

# Test 8: connection reset → block
run_test "connection reset triggers block" "block" \
    "$(mk_stop 'Error: connection reset by peer' 'sess-t8')"

# Test 10: "File has been modified since read" → block (self-healing transient)
run_test "modified-since-read triggers block" "block" \
    "$(mk_stop 'File has been modified since read — edit conflict' 'sess-t10')"

# Test 11: Cap-8 ceiling with new string → allow (no block)
SESSION_MOD="sess-mod-$(date +%s%N)"
COUNTER_MOD="/tmp/claude-resume-${SESSION_MOD}.count"
printf '%s' "8" >"$COUNTER_MOD" # simulate already at cap
MOD_MSG="$(mk_stop 'has been unexpectedly modified' "$SESSION_MOD")"
stdout_mod=$(printf '%s' "$MOD_MSG" | env STOP_HOOK_ACTIVE=false bash "$GUARD" 2>/dev/null || true)
if printf '%s' "$stdout_mod" | grep -q '"decision"[[:space:]]*:[[:space:]]*"block"'; then
    printf 'FAIL: cap-8 with unexpected-modified — 9th attempt should NOT block\n  stdout: %s\n' "$stdout_mod"
    fail=$((fail + 1))
else
    [ -n "${VERBOSE:-}" ] && printf 'PASS: cap-8 with unexpected-modified does not block\n'
    pass=$((pass + 1))
fi
rm -f "$COUNTER_MOD"

# Test 12: "socket connection was closed" → block (retryable)
run_test "socket connection was closed triggers block" "block" \
    "$(mk_stop 'Error: socket connection was closed unexpectedly' 'sess-t12')"

# Test 9: Retry count increments — first attempt sets count=1, second=2
SESSION_INC="sess-inc-$(date +%s%N)"
COUNTER_INC="/tmp/claude-resume-${SESSION_INC}.count"
rm -f "$COUNTER_INC"
INC_MSG="$(mk_stop 'Stream idle timeout occurred' "$SESSION_INC")"
printf '%s' "$INC_MSG" | env STOP_HOOK_ACTIVE=false bash "$GUARD" 2>/dev/null || true
count_after_1=$(cat "$COUNTER_INC" 2>/dev/null || echo "0")
printf '%s' "$INC_MSG" | env STOP_HOOK_ACTIVE=false bash "$GUARD" 2>/dev/null || true
count_after_2=$(cat "$COUNTER_INC" 2>/dev/null || echo "0")
if [ "$count_after_1" = "1" ] && [ "$count_after_2" = "2" ]; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: retry counter increments correctly (1 then 2)\n'
    pass=$((pass + 1))
else
    printf 'FAIL: retry counter incorrect — after 1st: %s, after 2nd: %s\n' "$count_after_1" "$count_after_2"
    fail=$((fail + 1))
fi
rm -f "$COUNTER_INC"

# ── Backoff tests (sleep PATH-stub) ─────────────────────────────────────────
# These tests verify the exponential-backoff schedule in stop-resume.sh.
# The fake sleep binary (SLEEP_STUB) records arg to SLEEP_CALLS without sleeping.

# Test A: attempt 1 → delay=0 → sleep NOT invoked
rm -f "$SLEEP_CALLS"
SESSION_BA="sess-ba-$(date +%s%N)"
BA_INPUT="$(mk_stop 'Stream idle timeout occurred' "$SESSION_BA")"
printf '%s' "$BA_INPUT" | env STOP_HOOK_ACTIVE=false PATH="$TMP_DIR:$PATH" bash "$GUARD" 2>/dev/null || true
if [ ! -f "$SLEEP_CALLS" ] || [ ! -s "$SLEEP_CALLS" ]; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: attempt 1 — no sleep invoked (delay=0)\n'
    pass=$((pass + 1))
else
    printf 'FAIL: attempt 1 — expected no sleep, sleep-calls: %s\n' "$(cat "$SLEEP_CALLS")"
    fail=$((fail + 1))
fi
rm -f "/tmp/claude-resume-${SESSION_BA}.count"

# Test B: attempt 2 → delay=60 → sleep 60 invoked
rm -f "$SLEEP_CALLS"
SESSION_BB="sess-bb-$(date +%s%N)"
COUNTER_BB="/tmp/claude-resume-${SESSION_BB}.count"
printf '%s' "1" >"$COUNTER_BB"
BB_INPUT="$(mk_stop 'Stream idle timeout occurred' "$SESSION_BB")"
printf '%s' "$BB_INPUT" | env STOP_HOOK_ACTIVE=false PATH="$TMP_DIR:$PATH" bash "$GUARD" 2>/dev/null || true
if [ -f "$SLEEP_CALLS" ] && grep -qx "60" "$SLEEP_CALLS"; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: attempt 2 — sleep 60 invoked\n'
    pass=$((pass + 1))
else
    printf 'FAIL: attempt 2 — expected sleep 60, sleep-calls: %s\n' "$(cat "$SLEEP_CALLS" 2>/dev/null || echo "(absent)")"
    fail=$((fail + 1))
fi
rm -f "$COUNTER_BB"

# Test C: attempt 4 → delay=300 (cap) → sleep 300 invoked
rm -f "$SLEEP_CALLS"
SESSION_BC="sess-bc-$(date +%s%N)"
COUNTER_BC="/tmp/claude-resume-${SESSION_BC}.count"
printf '%s' "3" >"$COUNTER_BC"
BC_INPUT="$(mk_stop 'Stream idle timeout occurred' "$SESSION_BC")"
printf '%s' "$BC_INPUT" | env STOP_HOOK_ACTIVE=false PATH="$TMP_DIR:$PATH" bash "$GUARD" 2>/dev/null || true
if [ -f "$SLEEP_CALLS" ] && grep -qx "300" "$SLEEP_CALLS"; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: attempt 4 — sleep 300 invoked (cap)\n'
    pass=$((pass + 1))
else
    printf 'FAIL: attempt 4 — expected sleep 300, sleep-calls: %s\n' "$(cat "$SLEEP_CALLS" 2>/dev/null || echo "(absent)")"
    fail=$((fail + 1))
fi
rm -f "$COUNTER_BC"

# Test D: non-retryable (401) → no sleep invoked
rm -f "$SLEEP_CALLS"
SESSION_BD="sess-bd-$(date +%s%N)"
BD_INPUT="$(mk_stop 'API Error: 401 Unauthorized' "$SESSION_BD")"
printf '%s' "$BD_INPUT" | env STOP_HOOK_ACTIVE=false PATH="$TMP_DIR:$PATH" bash "$GUARD" 2>/dev/null || true
if [ ! -f "$SLEEP_CALLS" ] || [ ! -s "$SLEEP_CALLS" ]; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: non-retryable (401) — no sleep invoked\n'
    pass=$((pass + 1))
else
    printf 'FAIL: non-retryable (401) — expected no sleep, sleep-calls: %s\n' "$(cat "$SLEEP_CALLS")"
    fail=$((fail + 1))
fi

# Test E: cap-8 retryable → exits without block → no sleep invoked
rm -f "$SLEEP_CALLS"
SESSION_BE="sess-be-$(date +%s%N)"
COUNTER_BE="/tmp/claude-resume-${SESSION_BE}.count"
printf '%s' "8" >"$COUNTER_BE"
BE_INPUT="$(mk_stop 'Stream idle timeout occurred' "$SESSION_BE")"
printf '%s' "$BE_INPUT" | env STOP_HOOK_ACTIVE=false PATH="$TMP_DIR:$PATH" bash "$GUARD" 2>/dev/null || true
if [ ! -f "$SLEEP_CALLS" ] || [ ! -s "$SLEEP_CALLS" ]; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: cap-8 — exits before sleep (no sleep invoked)\n'
    pass=$((pass + 1))
else
    printf 'FAIL: cap-8 — expected no sleep, sleep-calls: %s\n' "$(cat "$SLEEP_CALLS")"
    fail=$((fail + 1))
fi
rm -f "$COUNTER_BE"

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
