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
#   F.  FLAGGED isApiErrorMessage record with retryable string → block
#   G.  FLAGGED system/api_error record (error.message) with retryable string → block
#   H.  QUOTED-ONLY — retryable string only in prose + tool_result, NO flagged record → allow
#   I.  No TRANSCRIPT_PATH, prose-only retryable string → haystack empty → allow
#   J.  FLAGGED record with hard-fail (401) string → allow (hard-fail beats retryable)
#   K.  FLAGGED record with rate-limit (429) string → allow (rate-limit beats retryable)
#   L.  PRECEDENCE — flagged record with retryable+hard-fail mix → hard-fail wins → allow
#   M.  Non-numeric counter file → reset to 0, still blocks, counter rewritten to "1"
#   N.  Transport-fault "socket connection was closed" via system/api_error record → block

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/stop-resume.sh"

pass=0
fail=0

TMP_DIR="$(mktemp -d)"
reset_counters() {
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
        /tmp/claude-resume-sess-loop.count \
        /tmp/claude-resume-sess-tf.count \
        /tmp/claude-resume-sess-tg.count \
        /tmp/claude-resume-sess-th.count \
        /tmp/claude-resume-sess-ti.count \
        /tmp/claude-resume-sess-tj.count \
        /tmp/claude-resume-sess-tk.count \
        /tmp/claude-resume-sess-tl.count
}

teardown() {
    rm -rf "$TMP_DIR"
}

# Create a fake sleep binary in TMP_DIR that records its arg and exits 0.
# Tests that verify backoff behaviour prepend TMP_DIR to PATH so real sleep
# is never invoked (keeps the test suite fast even when delay=300).
SLEEP_STUB="$TMP_DIR/sleep"
SLEEP_CALLS="$TMP_DIR/sleep-calls"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$1" >> "%s"\n' "$SLEEP_CALLS" >"$SLEEP_STUB"
chmod +x "$SLEEP_STUB"
trap teardown EXIT
reset_counters # clean any leftovers from previous suite runs before tests start

run_test() {
    local desc="$1"
    local expected="$2" # "block" or "allow"
    local input="$3"
    local extra_env="${4:-}"

    local stdout
    stdout=$(printf '%s' "$input" | env \
        STOP_HOOK_ACTIVE=false \
        PATH="$TMP_DIR:$PATH" \
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

# Build a stop payload that points at a temp transcript file. The transcript's
# last lines decide classification (structural records only). last_assistant_message
# is settable independently to prove prose alone does NOT classify.
# Args: <session_id> <last_assistant_message> <transcript-jsonl-content>
mk_stop_transcript() {
    local session="$1"
    local last_msg="$2"
    local transcript_body="$3"
    local tfile
    tfile="$TMP_DIR/transcript-${session}.jsonl"
    printf '%s\n' "$transcript_body" >"$tfile"
    jq -n \
        --arg msg "$last_msg" \
        --arg sid "$session" \
        --arg tp "$tfile" \
        '{"hook_event_name":"Stop","last_assistant_message":$msg,"session_id":$sid,"transcript_path":$tp,"stop_hook_active":false}'
}

# Test 1: Stream idle timeout → block (via flagged transcript record)
run_test "stream idle timeout triggers block" "block" \
    "$(mk_stop_transcript 'sess-t1' '' \
        '{"isApiErrorMessage":true,"message":{"content":[{"type":"text","text":"Stream idle timeout occurred during response generation"}]}}')"

# Test 2: 401 authentication error → no block (hard fail; prose-only, allow regardless)
run_test "401 auth error does not retry" "allow" \
    "$(mk_stop 'API Error: 401 Unauthorized — invalid_api_key' 'sess-t2')"

# Test 3: 429 rate limit → no block (non-retryable; prose-only, allow regardless)
run_test "429 rate limit does not retry" "allow" \
    "$(mk_stop 'API Error: 429 rate_limit exceeded' 'sess-t3')"

# Test 4: Normal stop (no error text) → no block
run_test "normal stop (no error) does not block" "allow" \
    "$(mk_stop 'Task complete.' 'sess-t4')"

# Test 5: Retry cap — 9th attempt should NOT block (cap = 8)
SESSION_CAP="sess-cap-$(date +%s%N)"
COUNTER_FILE="/tmp/claude-resume-${SESSION_CAP}.count"
printf '%s' "8" >"$COUNTER_FILE" # simulate already at cap
RETRYABLE_MSG="$(mk_stop_transcript "$SESSION_CAP" '' \
    '{"isApiErrorMessage":true,"message":{"content":[{"type":"text","text":"Stream idle timeout occurred"}]}}')"
stdout_cap=$(printf '%s' "$RETRYABLE_MSG" | env STOP_HOOK_ACTIVE=false PATH="$TMP_DIR:$PATH" bash "$GUARD" 2>/dev/null || true)
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
stdout_loop=$(printf '%s' "$LOOP_INPUT" | env STOP_HOOK_ACTIVE=true PATH="$TMP_DIR:$PATH" bash "$GUARD" 2>/dev/null || true)
if printf '%s' "$stdout_loop" | grep -q '"decision"[[:space:]]*:[[:space:]]*"block"'; then
    printf 'FAIL: STOP_HOOK_ACTIVE=true should skip block\n  stdout: %s\n' "$stdout_loop"
    fail=$((fail + 1))
else
    [ -n "${VERBOSE:-}" ] && printf 'PASS: STOP_HOOK_ACTIVE=true skips block (loop guard)\n'
    pass=$((pass + 1))
fi

# Test 7: API 500 → block (retryable server error, via flagged transcript record)
run_test "API Error 500 triggers block" "block" \
    "$(mk_stop_transcript 'sess-t7' '' \
        '{"isApiErrorMessage":true,"message":{"content":[{"type":"text","text":"API Error: 500 Internal server error"}]}}')"

# Test 8: connection reset → block (via flagged transcript record)
run_test "connection reset triggers block" "block" \
    "$(mk_stop_transcript 'sess-t8' '' \
        '{"isApiErrorMessage":true,"message":{"content":[{"type":"text","text":"Error: connection reset by peer"}]}}')"

# Test 10: "File has been modified since read" → block (self-healing transient, via flagged record)
run_test "modified-since-read triggers block" "block" \
    "$(mk_stop_transcript 'sess-t10' '' \
        '{"isApiErrorMessage":true,"message":{"content":[{"type":"text","text":"File has been modified since read — edit conflict"}]}}')"

# Test 11: Cap-8 ceiling with new string → allow (no block)
SESSION_MOD="sess-mod-$(date +%s%N)"
COUNTER_MOD="/tmp/claude-resume-${SESSION_MOD}.count"
printf '%s' "8" >"$COUNTER_MOD" # simulate already at cap
MOD_MSG="$(mk_stop_transcript "$SESSION_MOD" '' \
    '{"isApiErrorMessage":true,"message":{"content":[{"type":"text","text":"has been unexpectedly modified"}]}}')"
stdout_mod=$(printf '%s' "$MOD_MSG" | env STOP_HOOK_ACTIVE=false PATH="$TMP_DIR:$PATH" bash "$GUARD" 2>/dev/null || true)
if printf '%s' "$stdout_mod" | grep -q '"decision"[[:space:]]*:[[:space:]]*"block"'; then
    printf 'FAIL: cap-8 with unexpected-modified — 9th attempt should NOT block\n  stdout: %s\n' "$stdout_mod"
    fail=$((fail + 1))
else
    [ -n "${VERBOSE:-}" ] && printf 'PASS: cap-8 with unexpected-modified does not block\n'
    pass=$((pass + 1))
fi
rm -f "$COUNTER_MOD"

# Test 12: "socket connection was closed" → block (retryable, via flagged transcript record)
run_test "socket connection was closed triggers block" "block" \
    "$(mk_stop_transcript 'sess-t12' '' \
        '{"isApiErrorMessage":true,"message":{"content":[{"type":"text","text":"Error: socket connection was closed unexpectedly"}]}}')"

# Test 9: Retry count increments — first attempt sets count=1, second=2
SESSION_INC="sess-inc-$(date +%s%N)"
COUNTER_INC="/tmp/claude-resume-${SESSION_INC}.count"
rm -f "$COUNTER_INC"
INC_MSG="$(mk_stop_transcript "$SESSION_INC" '' \
    '{"isApiErrorMessage":true,"message":{"content":[{"type":"text","text":"Stream idle timeout occurred"}]}}')"
printf '%s' "$INC_MSG" | env STOP_HOOK_ACTIVE=false PATH="$TMP_DIR:$PATH" bash "$GUARD" 2>/dev/null || true
count_after_1=$(cat "$COUNTER_INC" 2>/dev/null || echo "0")
printf '%s' "$INC_MSG" | env STOP_HOOK_ACTIVE=false PATH="$TMP_DIR:$PATH" bash "$GUARD" 2>/dev/null || true
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
BA_INPUT="$(mk_stop_transcript "$SESSION_BA" '' \
    '{"isApiErrorMessage":true,"message":{"content":[{"type":"text","text":"Stream idle timeout occurred"}]}}')"
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
BB_INPUT="$(mk_stop_transcript "$SESSION_BB" '' \
    '{"isApiErrorMessage":true,"message":{"content":[{"type":"text","text":"Stream idle timeout occurred"}]}}')"
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
BC_INPUT="$(mk_stop_transcript "$SESSION_BC" '' \
    '{"isApiErrorMessage":true,"message":{"content":[{"type":"text","text":"Stream idle timeout occurred"}]}}')"
printf '%s' "$BC_INPUT" | env STOP_HOOK_ACTIVE=false PATH="$TMP_DIR:$PATH" bash "$GUARD" 2>/dev/null || true
if [ -f "$SLEEP_CALLS" ] && grep -qx "300" "$SLEEP_CALLS"; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: attempt 4 — sleep 300 invoked (cap)\n'
    pass=$((pass + 1))
else
    printf 'FAIL: attempt 4 — expected sleep 300, sleep-calls: %s\n' "$(cat "$SLEEP_CALLS" 2>/dev/null || echo "(absent)")"
    fail=$((fail + 1))
fi
rm -f "$COUNTER_BC"

# Test D: non-retryable (401) → no sleep invoked (prose-only, allow regardless)
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
BE_INPUT="$(mk_stop_transcript "$SESSION_BE" '' \
    '{"isApiErrorMessage":true,"message":{"content":[{"type":"text","text":"Stream idle timeout occurred"}]}}')"
printf '%s' "$BE_INPUT" | env STOP_HOOK_ACTIVE=false PATH="$TMP_DIR:$PATH" bash "$GUARD" 2>/dev/null || true
if [ ! -f "$SLEEP_CALLS" ] || [ ! -s "$SLEEP_CALLS" ]; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: cap-8 — exits before sleep (no sleep invoked)\n'
    pass=$((pass + 1))
else
    printf 'FAIL: cap-8 — expected no sleep, sleep-calls: %s\n' "$(cat "$SLEEP_CALLS")"
    fail=$((fail + 1))
fi
rm -f "$COUNTER_BE"

# Test F: FLAGGED isApiErrorMessage record with retryable string → block
run_test "flagged isApiErrorMessage (stream idle) triggers block" "block" \
    "$(mk_stop_transcript 'sess-tf' '' \
        '{"isApiErrorMessage":true,"message":{"content":[{"type":"text","text":"Stream idle timeout occurred"}]}}')"

# Test G: FLAGGED system/api_error record (error.message) with retryable string → block
run_test "flagged system/api_error (529) triggers block" "block" \
    "$(mk_stop_transcript 'sess-tg' '' \
        '{"type":"system","subtype":"api_error","error":{"message":"API Error: 529 overloaded_error"}}')"

# Test H: QUOTED-ONLY — retryable string only in prose + tool_result, NO flagged
# record present → allow (the false-fire this pitch kills)
run_test "quoted-only error string (no flagged record) does not block" "allow" \
    "$(mk_stop_transcript 'sess-th' 'discussing Stream idle timeout in analysis' \
        '{"type":"user","message":{"content":[{"type":"tool_result","content":[{"type":"text","text":"Stream idle timeout occurred"}]}]}}')"

# Test I: retryable string present in PROSE only, NO transcript_path → haystack
# empty (hook lines 38-48 skip the jq scan) → allow. Proves transcript-absent
# turns never auto-resume even when last_assistant_message quotes a transient error.
run_test "no transcript_path, prose-only retryable → allow" "allow" \
    "$(mk_stop 'API Error: socket connection was closed unexpectedly' 'sess-ti')"

# Test J: FLAGGED record carrying a HARD-FAIL string → hard_fail beats any
# retryable token (hook lines 57-58, evaluated first) → allow. Covers hard-fail
# via a real flagged record, not just prose (Test 2).
run_test "flagged record with hard-fail (401) → allow" "allow" \
    "$(mk_stop_transcript 'sess-tj' '' \
        '{"type":"system","subtype":"api_error","error":{"message":"API Error: 401 invalid_api_key"}}')"

# Test K: FLAGGED record carrying a RATE-LIMIT (429) string → rate_limit beats
# retryable (hook lines 59-60) → allow. Covers 429 via a real flagged record.
run_test "flagged record with rate-limit (429) → allow" "allow" \
    "$(mk_stop_transcript 'sess-tk' '' \
        '{"type":"system","subtype":"api_error","error":{"message":"API Error: 429 rate_limit exceeded"}}')"

# Test L: PRECEDENCE — flagged record with BOTH a retryable (500) AND a hard-fail
# (400) token → hard_fail regex checked first (hook line 57) → allow. Locks the
# branch ORDER, not just individual matches.
run_test "flagged record with retryable+hard-fail mix → hard-fail wins → allow" "allow" \
    "$(mk_stop_transcript 'sess-tl' '' \
        '{"isApiErrorMessage":true,"message":{"content":[{"type":"text","text":"API Error: 500 Internal server error; also API Error: 400 bad request"}]}}')"

# Test M: NON-NUMERIC counter file → reset to 0 (hook lines 76-78) → still blocks,
# counter rewritten to "1". Covers the corrupt-counter recovery branch.
SESSION_NAN="sess-tm"
COUNTER_NAN="/tmp/claude-resume-${SESSION_NAN}.count"
printf '%s' "garbage" >"$COUNTER_NAN"
NAN_MSG="$(mk_stop_transcript "$SESSION_NAN" '' \
    '{"isApiErrorMessage":true,"message":{"content":[{"type":"text","text":"Stream idle timeout occurred"}]}}')"
stdout_nan=$(printf '%s' "$NAN_MSG" | env STOP_HOOK_ACTIVE=false PATH="$TMP_DIR:$PATH" bash "$GUARD" 2>/dev/null || true)
count_nan=$(cat "$COUNTER_NAN" 2>/dev/null || echo "X")
if printf '%s' "$stdout_nan" | grep -q '"decision"[[:space:]]*:[[:space:]]*"block"' && [ "$count_nan" = "1" ]; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: non-numeric counter resets to 0 then blocks (count=1)\n'
    pass=$((pass + 1))
else
    printf 'FAIL: non-numeric counter — expected block + count=1, got count=%s\n  stdout: %s\n' "$count_nan" "$stdout_nan"
    fail=$((fail + 1))
fi
rm -f "$COUNTER_NAN"

# Test N: transport-fault taxonomy THIS PITCH motivates — "socket connection was
# closed unexpectedly" via a system/api_error record (Test 12 used isApiErrorMessage;
# this asserts the same string through the SDK-event surface) → block.
run_test "system/api_error socket-closed (abort taxonomy) → block" "block" \
    "$(mk_stop_transcript 'sess-tn' '' \
        '{"type":"system","subtype":"api_error","error":{"message":"API Error: The socket connection was closed unexpectedly"}}')"

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
