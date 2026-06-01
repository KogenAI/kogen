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

# make_transcript <transcript_path> <log_path> — write synthetic JSONL
# recording a Write to <log_path>.
make_transcript() {
    local transcript_path="$1"
    local log_path="$2"
    printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"%s"}}]}}\n' \
        "$log_path" >"$transcript_path"
}

make_input() {
    local cwd="$1"
    local stop_active="${2:-false}"
    local last_msg="${3:-}"
    local transcript_path="${4:-}"
    jq -n \
        --arg cwd "$cwd" \
        --argjson stop_active "$stop_active" \
        --arg last_msg "$last_msg" \
        --arg transcript_path "$transcript_path" \
        '{"hook_event_name":"Stop","cwd":$cwd,"session_id":"testsession","stop_hook_active":$stop_active,"last_assistant_message":$last_msg,"transcript_path":$transcript_path}'
}

# ── Test 1: STOP_HOOK_ACTIVE=true → no block ────────────────────────────────
T1=$(make_project)
LOG1="$T1/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step1_test.md"
cat >"$LOG1" <<'MD'
## developer-phoenix-backend Section
## dev-gate Section
ALL CLEAR ✅
MD
make_transcript "$T1/transcript.jsonl" "$LOG1"
out=$(make_input "$T1" true "" "$T1/transcript.jsonl" | bash "$HOOK" 2>/dev/null || true)
assert_not_contains "stop_hook_active short-circuits (no block)" '"decision"' "$out"
rm -rf "$T1"

# ── Test 2: developer + ALL CLEAR, no reviewer → BLOCK ──────────────────────
T2=$(make_project)
LOG2="$T2/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step1_test.md"
cat >"$LOG2" <<'MD'
## developer-phoenix-backend Section

Some content

## dev-gate Section

Gate: make ci
ALL CLEAR ✅
MD
make_transcript "$T2/transcript.jsonl" "$LOG2"
out=$(make_input "$T2" false "" "$T2/transcript.jsonl" | bash "$HOOK" 2>/dev/null || true)
assert_contains "dev+gate ALL CLEAR no reviewer → BLOCK" '"decision"' "$out"
rm -rf "$T2"

# ── Test 3: developer + ALL CLEAR + reviewer, no curator, no committer → BLOCK ──
# Expect curator block (b1), not committer block.
T3=$(make_project)
LOG3="$T3/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step1_test.md"
cat >"$LOG3" <<'MD'
## developer-phoenix-backend Section

## dev-gate Section

ALL CLEAR ✅

## reviewer-phoenix Section

QUALITY APPROVED ✅
MD
make_transcript "$T3/transcript.jsonl" "$LOG3"
out=$(make_input "$T3" false "" "$T3/transcript.jsonl" | bash "$HOOK" 2>/dev/null || true)
assert_contains "reviewer no curator no committer → BLOCK (curator hint)" '"decision"' "$out"
assert_contains "block reason mentions context-curator" 'context-curator' "$out"
rm -rf "$T3"

# ── Test 4: developer + ALL CLEAR + reviewer + curator + committer → no block ─
T4=$(make_project)
LOG4="$T4/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step1_test.md"
cat >"$LOG4" <<'MD'
## developer-phoenix-backend Section

## dev-gate Section

ALL CLEAR ✅

## reviewer-phoenix Section

QUALITY APPROVED ✅

## context-curator Section

Done.

## committer Section

Committed.
MD
make_transcript "$T4/transcript.jsonl" "$LOG4"
out=$(make_input "$T4" false "" "$T4/transcript.jsonl" | bash "$HOOK" 2>/dev/null || true)
assert_not_contains "full cycle complete (with curator) → no block" '"decision"' "$out"
rm -rf "$T4"

# ── Test 5: INCONCLUSIVE in log → no block ───────────────────────────────────
T5=$(make_project)
LOG5="$T5/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step1_test.md"
cat >"$LOG5" <<'MD'
## developer-phoenix-backend Section

## dev-gate Section

INCONCLUSIVE ⚠️ pool-exhaustion
MD
make_transcript "$T5/transcript.jsonl" "$LOG5"
out=$(make_input "$T5" false "" "$T5/transcript.jsonl" | bash "$HOOK" 2>/dev/null || true)
assert_not_contains "INCONCLUSIVE in log → skip (no block)" '"decision"' "$out"
rm -rf "$T5"

# ── Test 6: no log in transcript → no block ─────────────────────────────────
T6=$(make_project)
# No transcript_path provided → helper returns empty → exit 0
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
make_transcript "$T7/transcript.jsonl" "$LOG7"
out=$(make_input "$T7" false "Should I proceed with the next step?" "$T7/transcript.jsonl" | bash "$HOOK" 2>/dev/null || true)
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
make_transcript "$T8/transcript.jsonl" "$LOG8"
out=$(make_input "$T8" false "Gate still running, checking back in shortly." "$T8/transcript.jsonl" | bash "$HOOK" 2>/dev/null || true)
assert_not_contains "async-wait signal → no block" '"decision"' "$out"
rm -rf "$T8"

# ── Test 9: phoenix-dev-gate Section accepted (renamed hook header) ───────────
T9=$(make_project)
LOG9="$T9/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_session.md"
cat >"$LOG9" <<'MD'
## developer-phoenix-frontend Section

## phoenix-dev-gate Section

Gate: make ci
ALL CLEAR ✅
MD
make_transcript "$T9/transcript.jsonl" "$LOG9"
out=$(make_input "$T9" false "" "$T9/transcript.jsonl" | bash "$HOOK" 2>/dev/null || true)
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
make_transcript "$T10/transcript.jsonl" "$LOG10"
out=$(make_input "$T10" false "" "$T10/transcript.jsonl" | bash "$HOOK" 2>/dev/null || true)
assert_not_contains "dev-gate FAILED (no ALL CLEAR) → no block by this hook" '"decision"' "$out"
rm -rf "$T10"

# ── Test 11: A+B regression — A's transcript, B's newer log on disk → A's log
# B has newer mtime; transcript only records A → hook must read A, block correctly.
T11A=$(make_project)
T11B=$(make_project)
LOG11A="$T11A/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step1_A.md"
cat >"$LOG11A" <<'MD'
## developer-phoenix-backend Section

## dev-gate Section

ALL CLEAR ✅
MD
sleep 1
LOG11B="$T11B/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step1_B.md"
cat >"$LOG11B" <<'MD'
# Step B — no reviewer yet
MD
# A's transcript only records A's log.
make_transcript "$T11A/transcript.jsonl" "$LOG11A"
out=$(make_input "$T11A" false "" "$T11A/transcript.jsonl" | bash "$HOOK" 2>/dev/null || true)
# Should block (dev+gate no reviewer) and NOT reference B's log in reason.
if printf '%s' "$out" | grep -q '"decision"' && ! printf '%s' "$out" | grep -qF "$LOG11B"; then
    printf 'PASS: A+B regression: blocked for correct log (A), B not referenced\n'
    pass=$((pass + 1))
else
    printf 'FAIL: A+B regression: wrong outcome or B referenced\n  out: %s\n' "$out"
    fail=$((fail + 1))
fi
rm -rf "$T11A" "$T11B"

# ── Test 12: reviewer present, curator absent, committer absent → BLOCK (curator) ─
T12=$(make_project)
LOG12="$T12/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step1_test.md"
cat >"$LOG12" <<'MD'
## developer-phoenix-backend Section

## dev-gate Section

ALL CLEAR ✅

## reviewer-phoenix Section

QUALITY APPROVED ✅
MD
make_transcript "$T12/transcript.jsonl" "$LOG12"
out=$(make_input "$T12" false "" "$T12/transcript.jsonl" | bash "$HOOK" 2>/dev/null || true)
assert_contains "reviewer+no curator+no committer → BLOCK mentioning context-curator" 'context-curator' "$out"
rm -rf "$T12"

# ── Test 13: reviewer + curator present, committer absent → BLOCK (committer) ─
T13=$(make_project)
LOG13="$T13/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step1_test.md"
cat >"$LOG13" <<'MD'
## developer-phoenix-backend Section

## dev-gate Section

ALL CLEAR ✅

## reviewer-phoenix Section

QUALITY APPROVED ✅

## context-curator Section

Done.
MD
make_transcript "$T13/transcript.jsonl" "$LOG13"
out=$(make_input "$T13" false "" "$T13/transcript.jsonl" | bash "$HOOK" 2>/dev/null || true)
assert_contains "reviewer+curator+no committer → BLOCK mentioning committer" '"decision"' "$out"
assert_contains "block reason mentions committer" 'committer' "$out"
rm -rf "$T13"

# ── Test 14: all sections (dev+gate+reviewer+curator+committer) → no block ────
T14=$(make_project)
LOG14="$T14/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step1_test.md"
cat >"$LOG14" <<'MD'
## developer-phoenix-backend Section

## dev-gate Section

ALL CLEAR ✅

## reviewer-phoenix Section

QUALITY APPROVED ✅

## context-curator Section

Done.

## committer Section

Committed.
MD
make_transcript "$T14/transcript.jsonl" "$LOG14"
out=$(make_input "$T14" false "" "$T14/transcript.jsonl" | bash "$HOOK" 2>/dev/null || true)
assert_not_contains "all five sections present → no block" '"decision"' "$out"
rm -rf "$T14"

# ── Test 15: git log behind (no verdict) → no block by this hook ─────────────
# This hook only checks section presence, not git state. No verdict → no block.
T15=$(make_project)
LOG15="$T15/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step1_test.md"
cat >"$LOG15" <<'MD'
## developer-phoenix-backend Section

## dev-gate Section

FAILED ❌ exit=1
MD
make_transcript "$T15/transcript.jsonl" "$LOG15"
out=$(make_input "$T15" false "" "$T15/transcript.jsonl" | bash "$HOOK" 2>/dev/null || true)
assert_not_contains "gate FAILED (no ALL CLEAR) → no block by this hook" '"decision"' "$out"
rm -rf "$T15"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
