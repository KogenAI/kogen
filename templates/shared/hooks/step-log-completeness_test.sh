#!/usr/bin/env bash
# step-log-completeness_test.sh — unit tests for step-log-completeness.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/step-log-completeness.sh"

pass=0
fail=0

assert_contains() {
    local desc="$1"
    local needle="$2"
    local haystack="$3"
    if printf '%s' "$haystack" | grep -q "$needle"; then
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
    if printf '%s' "$haystack" | grep -q "$needle"; then
        printf 'FAIL: %s\n  unexpected: %s\n  haystack: %s\n' "$desc" "$needle" "$haystack"
        fail=$((fail + 1))
    else
        printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    fi
}

make_project() {
    local dir
    dir=$(mktemp -d)
    mkdir -p "$dir/codegen/logging"
    printf '%s' "$dir"
}

make_input() {
    local cwd="$1"
    local stop_active="${2:-false}"
    local last_msg="${3:-}"
    jq -n \
        --arg cwd "$cwd" \
        --argjson stop_active "$stop_active" \
        --arg last_msg "$last_msg" \
        '{"hook_event_name":"Stop","cwd":$cwd,"session_id":"testsession","stop_hook_active":$stop_active,"last_assistant_message":$last_msg}'
}

# ── Test 1: STOP_HOOK_ACTIVE=true → no block ────────────────────────────────
T1=$(make_project)
LOG1="$T1/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step1_test.md"
cat >"$LOG1" <<'MD'
## developer-phoenix-backend Section
## dev-gate Section
ALL CLEAR ✅
MD
out=$(make_input "$T1" true | bash "$HOOK" 2>/dev/null || true)
assert_not_contains "stop_hook_active short-circuits (no block)" '"decision"' "$out"
rm -rf "$T1"

# ── Test 2: developer + ALL CLEAR, no reviewer → BLOCK ──────────────────────
T2=$(make_project)
LOG2="$T2/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step1_test.md"
cat >"$LOG2" <<'MD'
## developer-phoenix-backend Section

Some content

## dev-gate Section

Gate: make ci-fast
ALL CLEAR ✅
MD
out=$(make_input "$T2" false | bash "$HOOK" 2>/dev/null || true)
assert_contains "dev+gate ALL CLEAR no reviewer → BLOCK" '"decision"' "$out"
rm -rf "$T2"

# ── Test 3: developer + ALL CLEAR + reviewer, no committer → BLOCK ──────────
T3=$(make_project)
LOG3="$T3/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step1_test.md"
cat >"$LOG3" <<'MD'
## developer-phoenix-backend Section

## dev-gate Section

ALL CLEAR ✅

## reviewer-phoenix Section

QUALITY APPROVED ✅
MD
out=$(make_input "$T3" false | bash "$HOOK" 2>/dev/null || true)
assert_contains "reviewer no committer → BLOCK" '"decision"' "$out"
rm -rf "$T3"

# ── Test 4: developer + ALL CLEAR + reviewer + committer → no block ──────────
T4=$(make_project)
LOG4="$T4/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step1_test.md"
cat >"$LOG4" <<'MD'
## developer-phoenix-backend Section

## dev-gate Section

ALL CLEAR ✅

## reviewer-phoenix Section

QUALITY APPROVED ✅

## committer Section

Committed.
MD
out=$(make_input "$T4" false | bash "$HOOK" 2>/dev/null || true)
assert_not_contains "full cycle complete → no block" '"decision"' "$out"
rm -rf "$T4"

# ── Test 5: INCONCLUSIVE in log → no block ───────────────────────────────────
T5=$(make_project)
LOG5="$T5/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step1_test.md"
cat >"$LOG5" <<'MD'
## developer-phoenix-backend Section

## dev-gate Section

INCONCLUSIVE ⚠️ pool-exhaustion
MD
out=$(make_input "$T5" false | bash "$HOOK" 2>/dev/null || true)
assert_not_contains "INCONCLUSIVE in log → skip (no block)" '"decision"' "$out"
rm -rf "$T5"

# ── Test 6: no log found → no block ─────────────────────────────────────────
T6=$(make_project)
# No log files created
out=$(make_input "$T6" false | bash "$HOOK" 2>/dev/null || true)
assert_not_contains "no log → no block" '"decision"' "$out"
rm -rf "$T6"

# ── Test 7: last message is a question → no block ────────────────────────────
T7=$(make_project)
LOG7="$T7/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step1_test.md"
cat >"$LOG7" <<'MD'
## developer-phoenix-backend Section

## dev-gate Section

ALL CLEAR ✅
MD
out=$(make_input "$T7" false "Should I proceed with the next step?" | bash "$HOOK" 2>/dev/null || true)
assert_not_contains "intent question → no block" '"decision"' "$out"
rm -rf "$T7"

# ── Test 8: async-wait signal in last message → no block ─────────────────────
T8=$(make_project)
LOG8="$T8/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step1_test.md"
cat >"$LOG8" <<'MD'
## developer-phoenix-backend Section

## dev-gate Section

ALL CLEAR ✅
MD
out=$(make_input "$T8" false "Gate still running, checking back in shortly." | bash "$HOOK" 2>/dev/null || true)
assert_not_contains "async-wait signal → no block" '"decision"' "$out"
rm -rf "$T8"

# ── Test 9: phoenix-dev-gate Section accepted (renamed hook header) ───────────
T9=$(make_project)
LOG9="$T9/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_session.md"
cat >"$LOG9" <<'MD'
## developer-phoenix-frontend Section

## phoenix-dev-gate Section

Gate: make ci-fast
ALL CLEAR ✅
MD
out=$(make_input "$T9" false | bash "$HOOK" 2>/dev/null || true)
assert_contains "phoenix-dev-gate Section header accepted for ALL CLEAR" '"decision"' "$out"
rm -rf "$T9"

# ── Test 10: dev-gate Section FAILED (not ALL CLEAR) → no block by this hook ─
# (dev-gate failure is handled by phoenix-dev-gate.sh re-spawn, not this hook)
T10=$(make_project)
LOG10="$T10/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step1_test.md"
cat >"$LOG10" <<'MD'
## developer-phoenix-backend Section

## dev-gate Section

FAILED ❌ exit=1
MD
out=$(make_input "$T10" false | bash "$HOOK" 2>/dev/null || true)
assert_not_contains "dev-gate FAILED (no ALL CLEAR) → no block by this hook" '"decision"' "$out"
rm -rf "$T10"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
