#!/bin/bash
# developer-no-self-gate-reset_test.sh — unit tests for developer-no-self-gate-reset.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/developer-no-self-gate-reset.sh"

pass=0
fail=0

make_input() {
    local agent="$1"
    local sid="$2"
    jq -n \
        --arg agent "$agent" \
        --arg sid "$sid" \
        '{"hook_event_name":"SubagentStop","agent_type":$agent,"agent_id":"abc","session_id":$sid,"cwd":"/tmp"}'
}

# ── Test 1: developer-phoenix-backend removes counter file ───────────────────
SID1="reset-test-1-$$"
COUNTER1="/tmp/codegen-self-gate-${SID1}.count"
printf '2' >"$COUNTER1"
make_input "developer-phoenix-backend" "$SID1" | bash "$HOOK" 2>/dev/null || true
if [ ! -f "$COUNTER1" ]; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: developer-phoenix-backend counter file removed\n'
    pass=$((pass + 1))
else
    printf 'FAIL: developer-phoenix-backend counter file NOT removed\n'
    fail=$((fail + 1))
fi
rm -f "$COUNTER1"

# ── Test 2: developer-phoenix-frontend removes counter file ──────────────────
SID2="reset-test-2-$$"
COUNTER2="/tmp/codegen-self-gate-${SID2}.count"
printf '1' >"$COUNTER2"
make_input "developer-phoenix-frontend" "$SID2" | bash "$HOOK" 2>/dev/null || true
if [ ! -f "$COUNTER2" ]; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: developer-phoenix-frontend counter file removed\n'
    pass=$((pass + 1))
else
    printf 'FAIL: developer-phoenix-frontend counter file NOT removed\n'
    fail=$((fail + 1))
fi
rm -f "$COUNTER2"

# ── Test 3: developer-html removes counter file ──────────────────────────────
SID3="reset-test-3-$$"
COUNTER3="/tmp/codegen-self-gate-${SID3}.count"
printf '3' >"$COUNTER3"
make_input "developer-html" "$SID3" | bash "$HOOK" 2>/dev/null || true
if [ ! -f "$COUNTER3" ]; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: developer-html counter file removed\n'
    pass=$((pass + 1))
else
    printf 'FAIL: developer-html counter file NOT removed\n'
    fail=$((fail + 1))
fi
rm -f "$COUNTER3"

# ── Test 4: non-developer agent → counter file untouched ─────────────────────
SID4="reset-test-4-$$"
COUNTER4="/tmp/codegen-self-gate-${SID4}.count"
printf '2' >"$COUNTER4"
make_input "reviewer-phoenix" "$SID4" | bash "$HOOK" 2>/dev/null || true
if [ -f "$COUNTER4" ]; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: reviewer agent does NOT remove counter file\n'
    pass=$((pass + 1))
else
    printf 'FAIL: reviewer agent unexpectedly removed counter file\n'
    fail=$((fail + 1))
fi
rm -f "$COUNTER4"

# ── Test 5: no counter file → no error ───────────────────────────────────────
SID5="reset-test-5-$$"
COUNTER5="/tmp/codegen-self-gate-${SID5}.count"
rm -f "$COUNTER5"
make_input "developer-vite" "$SID5" | bash "$HOOK" 2>/dev/null
rc=$?
if [ "$rc" = "0" ]; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: no counter file → exits cleanly (rc=0)\n'
    pass=$((pass + 1))
else
    printf 'FAIL: no counter file → exit %s (expected 0)\n' "$rc"
    fail=$((fail + 1))
fi

# ── Test 6: developer-hugo removes counter file ──────────────────────────────
SID6="reset-test-6-$$"
COUNTER6="/tmp/codegen-self-gate-${SID6}.count"
printf '1' >"$COUNTER6"
make_input "developer-hugo" "$SID6" | bash "$HOOK" 2>/dev/null || true
if [ ! -f "$COUNTER6" ]; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: developer-hugo counter file removed\n'
    pass=$((pass + 1))
else
    printf 'FAIL: developer-hugo counter file NOT removed\n'
    fail=$((fail + 1))
fi
rm -f "$COUNTER6"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
