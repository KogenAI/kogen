#!/usr/bin/env bash
# cycle-state_test.sh — unit tests for cycle-state.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/cycle-state.sh"

pass=0
fail=0

assert_eq() {
    if [ "$2" = "$3" ]; then
        pass=$((pass + 1))
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$1"
    else
        printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"
        fail=$((fail + 1))
    fi
}

# Setup: use a temp dir per test group to avoid cross-test pollution.

# --- Test 1: write GATED+clear → cycle_state_get = GATED ---
T1=$(mktemp -d)
write_cycle_state "GATED" "/logs/step1.md" "sess1" "clear" "$T1"
got=$(cycle_state_get "$T1")
assert_eq "write GATED+clear → state=GATED" "GATED" "$got"
rm -rf "$T1"

# --- Test 2: write GATED+clear → cycle_state_verdict = clear ---
T2=$(mktemp -d)
write_cycle_state "GATED" "/logs/step1.md" "sess2" "clear" "$T2"
got=$(cycle_state_verdict "$T2")
assert_eq "write GATED+clear → verdict=clear" "clear" "$got"
rm -rf "$T2"

# --- Test 3: write GATED+failed → verdict = failed ---
T3=$(mktemp -d)
write_cycle_state "GATED" "/logs/step1.md" "sess3" "failed" "$T3"
got=$(cycle_state_verdict "$T3")
assert_eq "write GATED+failed → verdict=failed" "failed" "$got"
rm -rf "$T3"

# --- Test 4: write GATED+inconclusive → verdict = inconclusive ---
T4=$(mktemp -d)
write_cycle_state "GATED" "/logs/step1.md" "sess4" "inconclusive" "$T4"
got=$(cycle_state_verdict "$T4")
assert_eq "write GATED+inconclusive → verdict=inconclusive" "inconclusive" "$got"
rm -rf "$T4"

# --- Test 5: write REVIEWED (empty verdict) → state=REVIEWED, verdict="" ---
T5=$(mktemp -d)
write_cycle_state "REVIEWED" "/logs/step1.md" "sess5" "" "$T5"
state5=$(cycle_state_get "$T5")
verdict5=$(cycle_state_verdict "$T5")
assert_eq "write REVIEWED → state=REVIEWED" "REVIEWED" "$state5"
assert_eq "write REVIEWED → verdict empty string" "" "$verdict5"
rm -rf "$T5"

# --- Test 6: write CURATED → state=CURATED ---
T6=$(mktemp -d)
write_cycle_state "CURATED" "/logs/step1.md" "sess6" "" "$T6"
got=$(cycle_state_get "$T6")
assert_eq "write CURATED → state=CURATED" "CURATED" "$got"
rm -rf "$T6"

# --- Test 7: write COMMITTED → state=COMMITTED ---
T7=$(mktemp -d)
write_cycle_state "COMMITTED" "/logs/step1.md" "sess7" "" "$T7"
got=$(cycle_state_get "$T7")
assert_eq "write COMMITTED → state=COMMITTED" "COMMITTED" "$got"
rm -rf "$T7"

# --- Test 8: step_log roundtrip ---
T8=$(mktemp -d)
write_cycle_state "GATED" "/some/path/codegen/logging/20260614_step1.md" "sess8" "clear" "$T8"
got=$(cycle_state_step_log "$T8")
assert_eq "step_log roundtrip" "/some/path/codegen/logging/20260614_step1.md" "$got"
rm -rf "$T8"

# --- Test 9: session_id roundtrip ---
T9=$(mktemp -d)
write_cycle_state "GATED" "/logs/step1.md" "my-unique-session-id-xyz" "clear" "$T9"
got=$(cycle_state_session_id "$T9")
assert_eq "session_id roundtrip" "my-unique-session-id-xyz" "$got"
rm -rf "$T9"

# --- Test 10: cycle_state_get on missing dir → "" (no crash) ---
T10=$(mktemp -d)
got=$(cycle_state_get "$T10/does-not-exist")
assert_eq "cycle_state_get missing dir → empty string" "" "$got"
rm -rf "$T10"

# --- Test 11: cycle_state_verdict missing file → "" ---
T11=$(mktemp -d)
got=$(cycle_state_verdict "$T11")
assert_eq "cycle_state_verdict missing file → empty string" "" "$got"
rm -rf "$T11"

# --- Test 12: malformed JSON → cycle_state_get returns "" (2>/dev/null) ---
T12=$(mktemp -d)
mkdir -p "$T12/codegen/gate-pending"
printf 'NOT VALID JSON {{{' >"$T12/codegen/gate-pending/cycle-state.json"
got=$(cycle_state_get "$T12")
assert_eq "malformed JSON → state empty string" "" "$got"
rm -rf "$T12"

# --- Test 13: overwrite: GATED then REVIEWED → state = REVIEWED (last write wins) ---
T13=$(mktemp -d)
write_cycle_state "GATED" "/logs/step1.md" "sess13" "clear" "$T13"
write_cycle_state "REVIEWED" "/logs/step1.md" "sess13" "" "$T13"
got=$(cycle_state_get "$T13")
assert_eq "overwrite: GATED then REVIEWED → REVIEWED" "REVIEWED" "$got"
rm -rf "$T13"

# --- Test 14: mkdir -p creates gate-pending when absent ---
T14=$(mktemp -d)
# Do not pre-create gate-pending
write_cycle_state "GATED" "/logs/step1.md" "sess14" "clear" "$T14"
if [ -f "$T14/codegen/gate-pending/cycle-state.json" ]; then
    pass=$((pass + 1))
    [ -n "${VERBOSE:-}" ] && printf 'PASS: mkdir-p creates gate-pending when absent\n'
else
    printf 'FAIL: mkdir-p did not create gate-pending directory\n'
    fail=$((fail + 1))
fi
rm -rf "$T14"

# --- Test 15: JSON is valid (jq . succeeds) ---
T15=$(mktemp -d)
write_cycle_state "GATED" "/logs/step1.md" "sess15" "clear" "$T15"
if jq . "$T15/codegen/gate-pending/cycle-state.json" >/dev/null 2>&1; then
    pass=$((pass + 1))
    [ -n "${VERBOSE:-}" ] && printf 'PASS: written JSON is valid\n'
else
    printf 'FAIL: written cycle-state.json is not valid JSON\n'
    fail=$((fail + 1))
fi
rm -rf "$T15"

# --- Test 16: updated_at field present and ISO-shaped ---
T16=$(mktemp -d)
write_cycle_state "GATED" "/logs/step1.md" "sess16" "clear" "$T16"
updated_at=$(jq -r '.updated_at // ""' "$T16/codegen/gate-pending/cycle-state.json" 2>/dev/null || printf '')
if printf '%s' "$updated_at" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'; then
    pass=$((pass + 1))
    [ -n "${VERBOSE:-}" ] && printf 'PASS: updated_at present and ISO-shaped\n'
else
    printf 'FAIL: updated_at absent or not ISO-shaped: %s\n' "$updated_at"
    fail=$((fail + 1))
fi
rm -rf "$T16"

# ── Tests 17–31: cycle_state_is_terminal, cycle_state_next, cycle_state_role ──

# Test 17: cycle_state_is_terminal COMMITTED → true (return 0)
if cycle_state_is_terminal "COMMITTED"; then
    pass=$((pass + 1))
    [ -n "${VERBOSE:-}" ] && printf 'PASS: cycle_state_is_terminal COMMITTED → true\n'
else
    printf 'FAIL: cycle_state_is_terminal COMMITTED → expected true, got false\n'
    fail=$((fail + 1))
fi

# Test 18: cycle_state_is_terminal GATED → false
if cycle_state_is_terminal "GATED"; then
    printf 'FAIL: cycle_state_is_terminal GATED → expected false, got true\n'
    fail=$((fail + 1))
else
    pass=$((pass + 1))
    [ -n "${VERBOSE:-}" ] && printf 'PASS: cycle_state_is_terminal GATED → false\n'
fi

# Test 19: cycle_state_is_terminal REVIEWED → false
if cycle_state_is_terminal "REVIEWED"; then
    printf 'FAIL: cycle_state_is_terminal REVIEWED → expected false, got true\n'
    fail=$((fail + 1))
else
    pass=$((pass + 1))
    [ -n "${VERBOSE:-}" ] && printf 'PASS: cycle_state_is_terminal REVIEWED → false\n'
fi

# Test 20: cycle_state_is_terminal CURATED → false
if cycle_state_is_terminal "CURATED"; then
    printf 'FAIL: cycle_state_is_terminal CURATED → expected false, got true\n'
    fail=$((fail + 1))
else
    pass=$((pass + 1))
    [ -n "${VERBOSE:-}" ] && printf 'PASS: cycle_state_is_terminal CURATED → false\n'
fi

# Test 21: cycle_state_is_terminal garbage → false
if cycle_state_is_terminal "GARBAGE_STATE"; then
    printf 'FAIL: cycle_state_is_terminal GARBAGE_STATE → expected false, got true\n'
    fail=$((fail + 1))
else
    pass=$((pass + 1))
    [ -n "${VERBOSE:-}" ] && printf 'PASS: cycle_state_is_terminal garbage → false\n'
fi

# Test 22: cycle_state_next GATED → REVIEWED
got=$(cycle_state_next "GATED")
assert_eq "cycle_state_next GATED → REVIEWED" "REVIEWED" "$got"

# Test 23: cycle_state_next REVIEWED → CURATED
got=$(cycle_state_next "REVIEWED")
assert_eq "cycle_state_next REVIEWED → CURATED" "CURATED" "$got"

# Test 24: cycle_state_next CURATED → COMMITTED
got=$(cycle_state_next "CURATED")
assert_eq "cycle_state_next CURATED → COMMITTED" "COMMITTED" "$got"

# Test 25: cycle_state_next COMMITTED → "" (terminal, no successor)
got=$(cycle_state_next "COMMITTED")
assert_eq "cycle_state_next COMMITTED → empty" "" "$got"

# Test 26: cycle_state_next garbage → "" (unknown, no successor)
got=$(cycle_state_next "GARBAGE_STATE")
assert_eq "cycle_state_next garbage → empty" "" "$got"

# Test 27: cycle_state_role REVIEWED → context-curator
got=$(cycle_state_role "REVIEWED")
assert_eq "cycle_state_role REVIEWED → context-curator" "context-curator" "$got"

# Test 28: cycle_state_role CURATED → committer
got=$(cycle_state_role "CURATED")
assert_eq "cycle_state_role CURATED → committer" "committer" "$got"

# Test 29: cycle_state_role COMMITTED → "" (terminal, no next role)
got=$(cycle_state_role "COMMITTED")
assert_eq "cycle_state_role COMMITTED → empty" "" "$got"

# Test 30: cycle_state_role GATED → "" (first state, no prior block role)
got=$(cycle_state_role "GATED")
assert_eq "cycle_state_role GATED → empty" "" "$got"

# Test 31: cycle_state_role unknown → ""
got=$(cycle_state_role "UNKNOWN_STATE")
assert_eq "cycle_state_role unknown → empty" "" "$got"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
