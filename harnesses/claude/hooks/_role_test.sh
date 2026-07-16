#!/bin/bash
# _role_test.sh — unit tests for _role.sh (resolve_role / is_build_mode)
#
# Tests:
#   1: unset CLAUDE_ROLE/PI_ROLE → resolve_role empty, is_build_mode active (0)
#   2: CLAUDE_ROLE=build → is_build_mode active (0)
#   3: CLAUDE_ROLE=unknown-role → is_build_mode active (0), fail-safe
#   4: CLAUDE_ROLE=shape → is_build_mode skip (1)
#   5: CLAUDE_ROLE=debug → is_build_mode skip (1)
#   6: CLAUDE_ROLE=ops → is_build_mode skip (1)
#   7: CLAUDE_ROLE=experiment → is_build_mode skip (1)
#   8: CLAUDE_ROLE=refactor → is_build_mode skip (1)
#   9: CLAUDE_ROLE=babysit → is_build_mode skip (1)
#  10: PI_ROLE=babysit → is_build_mode skip (1) — PI_ROLE parity
#  11: CLAUDE_ROLE precedence over PI_ROLE when both set

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

pass=0
fail=0

run_is_build_mode() {
    local desc="$1"
    local expected_active="$2" # "1" = is_build_mode returns 0 (active); "0" = returns 1 (skip)
    shift 2

    local rc=0
    env "$@" bash -c "source '$SCRIPT_DIR/_role.sh'; is_build_mode" || rc=$?

    local got_active
    if [ "$rc" = "0" ]; then
        got_active="1"
    else
        got_active="0"
    fi

    if [ "$got_active" = "$expected_active" ]; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s — expected active=%s, got active=%s (rc=%s)\n' \
            "$desc" "$expected_active" "$got_active" "$rc"
        fail=$((fail + 1))
    fi
}

run_resolve_role() {
    local desc="$1"
    local expected="$2"
    shift 2

    local got
    got=$(env "$@" bash -c "source '$SCRIPT_DIR/_role.sh'; resolve_role")

    if [ "$got" = "$expected" ]; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s — expected %q, got %q\n' "$desc" "$expected" "$got"
        fail=$((fail + 1))
    fi
}

# Test 1: unset both → resolve_role empty, is_build_mode active
run_resolve_role "unset CLAUDE_ROLE/PI_ROLE → resolve_role empty" ""
run_is_build_mode "unset CLAUDE_ROLE/PI_ROLE → is_build_mode active" "1"

# Test 2: CLAUDE_ROLE=build → active
run_is_build_mode "CLAUDE_ROLE=build → is_build_mode active" "1" CLAUDE_ROLE=build

# Test 3: unknown role → fail-safe active
run_is_build_mode "CLAUDE_ROLE=unknown-role → is_build_mode active (fail-safe)" "1" CLAUDE_ROLE=unknown-role

# Test 4-8: named investigative roles → skip
run_is_build_mode "CLAUDE_ROLE=shape → is_build_mode skip" "0" CLAUDE_ROLE=shape
run_is_build_mode "CLAUDE_ROLE=debug → is_build_mode skip" "0" CLAUDE_ROLE=debug
run_is_build_mode "CLAUDE_ROLE=ops → is_build_mode skip" "0" CLAUDE_ROLE=ops
run_is_build_mode "CLAUDE_ROLE=experiment → is_build_mode skip" "0" CLAUDE_ROLE=experiment
run_is_build_mode "CLAUDE_ROLE=refactor → is_build_mode skip" "0" CLAUDE_ROLE=refactor

# Test 9: babysit — the new mode under test
run_is_build_mode "CLAUDE_ROLE=babysit → is_build_mode skip" "0" CLAUDE_ROLE=babysit

# Test 10: PI_ROLE parity
run_is_build_mode "PI_ROLE=babysit → is_build_mode skip" "0" PI_ROLE=babysit

# Test 11: CLAUDE_ROLE precedence over PI_ROLE
run_resolve_role "CLAUDE_ROLE precedence over PI_ROLE" "babysit" CLAUDE_ROLE=babysit PI_ROLE=ops

echo ""
echo "$pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi
