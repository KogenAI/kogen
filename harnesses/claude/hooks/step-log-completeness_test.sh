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
    if printf '%s' "$haystack" | grep -q "$needle"; then
        printf 'FAIL: %s\n  unexpected: %s\n  haystack: %s\n' "$desc" "$needle" "$haystack"
        fail=$((fail + 1))
    else
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
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

write_cycle_state_fixture() {
    local dir="$1"
    local state="$2"
    local step_log="$3"
    local verdict="${4:-}"
    mkdir -p "$dir/codegen/gate-pending"
    jq -n \
        --arg state "$state" \
        --arg step_log "$step_log" \
        --arg session_id "test-session" \
        --arg verdict "$verdict" \
        --arg updated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{state:$state,step_log:$step_log,session_id:$session_id,verdict:$verdict,updated_at:$updated_at}' \
        >"$dir/codegen/gate-pending/cycle-state.json"
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

# ── Test 2: GATED+verdict=clear, no reviewer → BLOCK ────────────────────────
T2=$(make_project)
LOG2="$T2/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step1_test.md"
cat >"$LOG2" <<'MD'
## developer-phoenix-backend Section

Some content

## dev-gate Section

Gate: make ci
ALL CLEAR ✅
MD
write_cycle_state_fixture "$T2" "GATED" "$LOG2" "clear"
make_transcript "$T2/transcript.jsonl" "$LOG2"
out=$(make_input "$T2" false "" "$T2/transcript.jsonl" | bash "$HOOK" 2>/dev/null || true)
assert_contains "GATED+verdict=clear no reviewer → BLOCK" '"decision"' "$out"
rm -rf "$T2"

# ── Test 3: REVIEWED → BLOCK (context-curator not run) ──────────────────────
T3=$(make_project)
LOG3="$T3/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step1_test.md"
cat >"$LOG3" <<'MD'
## developer-phoenix-backend Section

## dev-gate Section

ALL CLEAR ✅

## reviewer-phoenix Section

QUALITY APPROVED ✅
MD
write_cycle_state_fixture "$T3" "REVIEWED" "$LOG3" ""
make_transcript "$T3/transcript.jsonl" "$LOG3"
out=$(make_input "$T3" false "" "$T3/transcript.jsonl" | bash "$HOOK" 2>/dev/null || true)
assert_contains "REVIEWED → BLOCK (context-curator hint)" '"decision"' "$out"
assert_contains "block reason mentions context-curator" 'context-curator' "$out"
rm -rf "$T3"

# ── Test 4: COMMITTED + step_log match → no block (full cycle) ───────────────
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
write_cycle_state_fixture "$T4" "COMMITTED" "$LOG4" ""
make_transcript "$T4/transcript.jsonl" "$LOG4"
out=$(make_input "$T4" false "" "$T4/transcript.jsonl" | bash "$HOOK" 2>/dev/null || true)
assert_not_contains "COMMITTED (full cycle) → no block" '"decision"' "$out"
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

# ── Test 9: GATED+verdict=clear (phoenix-dev-gate) → BLOCK ──────────────────
T9=$(make_project)
LOG9="$T9/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_session.md"
cat >"$LOG9" <<'MD'
## developer-phoenix-frontend Section

## phoenix-dev-gate Section

Gate: make ci
ALL CLEAR ✅
MD
write_cycle_state_fixture "$T9" "GATED" "$LOG9" "clear"
make_transcript "$T9/transcript.jsonl" "$LOG9"
out=$(make_input "$T9" false "" "$T9/transcript.jsonl" | bash "$HOOK" 2>/dev/null || true)
assert_contains "GATED+verdict=clear → BLOCK (reviewer not run)" '"decision"' "$out"
rm -rf "$T9"

# ── Test 10: GATED+verdict=failed → no block by this hook ───────────────────
# (gate failure handled by phoenix-dev-gate.sh re-spawn)
T10=$(make_project)
LOG10="$T10/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step1_test.md"
cat >"$LOG10" <<'MD'
## developer-phoenix-backend Section

## dev-gate Section

FAILED ❌ exit=1
MD
write_cycle_state_fixture "$T10" "GATED" "$LOG10" "failed"
make_transcript "$T10/transcript.jsonl" "$LOG10"
out=$(make_input "$T10" false "" "$T10/transcript.jsonl" | bash "$HOOK" 2>/dev/null || true)
assert_not_contains "GATED+verdict=failed → no block by this hook" '"decision"' "$out"
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
write_cycle_state_fixture "$T11A" "GATED" "$LOG11A" "clear"
sleep 1
LOG11B="$T11B/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step1_B.md"
cat >"$LOG11B" <<'MD'
# Step B — no reviewer yet
MD
# A's transcript only records A's log.
make_transcript "$T11A/transcript.jsonl" "$LOG11A"
out=$(make_input "$T11A" false "" "$T11A/transcript.jsonl" | bash "$HOOK" 2>/dev/null || true)
# Should block (GATED+clear no reviewer) and NOT reference B's log in reason.
if printf '%s' "$out" | grep -q '"decision"' && ! printf '%s' "$out" | grep -qF "$LOG11B"; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: A+B regression: blocked for correct log (A), B not referenced\n'
    pass=$((pass + 1))
else
    printf 'FAIL: A+B regression: wrong outcome or B referenced\n  out: %s\n' "$out"
    fail=$((fail + 1))
fi
rm -rf "$T11A" "$T11B"

# ── Test 12: REVIEWED + no curator → BLOCK (context-curator) ────────────────
T12=$(make_project)
LOG12="$T12/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step1_test.md"
cat >"$LOG12" <<'MD'
## developer-phoenix-backend Section

## dev-gate Section

ALL CLEAR ✅

## reviewer-phoenix Section

QUALITY APPROVED ✅
MD
write_cycle_state_fixture "$T12" "REVIEWED" "$LOG12" ""
make_transcript "$T12/transcript.jsonl" "$LOG12"
out=$(make_input "$T12" false "" "$T12/transcript.jsonl" | bash "$HOOK" 2>/dev/null || true)
assert_contains "REVIEWED+no curator+no committer → BLOCK mentioning context-curator" 'context-curator' "$out"
rm -rf "$T12"

# ── Test 13: CURATED + no committer → BLOCK (committer) ─────────────────────
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
write_cycle_state_fixture "$T13" "CURATED" "$LOG13" ""
make_transcript "$T13/transcript.jsonl" "$LOG13"
out=$(make_input "$T13" false "" "$T13/transcript.jsonl" | bash "$HOOK" 2>/dev/null || true)
assert_contains "CURATED+no committer → BLOCK mentioning committer" '"decision"' "$out"
assert_contains "block reason mentions committer" 'committer' "$out"
rm -rf "$T13"

# ── Test 14: COMMITTED + all sections → no block ─────────────────────────────
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
write_cycle_state_fixture "$T14" "COMMITTED" "$LOG14" ""
make_transcript "$T14/transcript.jsonl" "$LOG14"
out=$(make_input "$T14" false "" "$T14/transcript.jsonl" | bash "$HOOK" 2>/dev/null || true)
assert_not_contains "COMMITTED+all sections → no block" '"decision"' "$out"
rm -rf "$T14"

# ── Test 15: GATED+verdict=failed (gate FAILED) → no block by this hook ──────
T15=$(make_project)
LOG15="$T15/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step1_test.md"
cat >"$LOG15" <<'MD'
## developer-phoenix-backend Section

## dev-gate Section

FAILED ❌ exit=1
MD
write_cycle_state_fixture "$T15" "GATED" "$LOG15" "failed"
make_transcript "$T15/transcript.jsonl" "$LOG15"
out=$(make_input "$T15" false "" "$T15/transcript.jsonl" | bash "$HOOK" 2>/dev/null || true)
assert_not_contains "GATED+verdict=failed → no block by this hook" '"decision"' "$out"
rm -rf "$T15"

# ── Test 16: GATED+verdict=failed → no block (cycle-state authoritative) ─────
# Old: gate-result.json verdict=failed overrides log ALL CLEAR → no block
# New: cycle-state=GATED+verdict=failed → no block (same semantics via cycle-state)
T16=$(make_project)
LOG16="$T16/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step1_test.md"
cat >"$LOG16" <<'MD'
## developer-phoenix-backend Section

## dev-gate Section

ALL CLEAR ✅
MD
write_cycle_state_fixture "$T16" "GATED" "$LOG16" "failed"
make_transcript "$T16/transcript.jsonl" "$LOG16"
out=$(make_input "$T16" false "" "$T16/transcript.jsonl" | bash "$HOOK" 2>/dev/null || true)
assert_not_contains "GATED+verdict=failed → no block (cycle-state authoritative)" '"decision"' "$out"
rm -rf "$T16"

# ── Test 17: GATED+verdict=clear → BLOCK (cycle-state authoritative) ─────────
# Old: gate-result.json verdict=clear enables block even without log marker
# New: cycle-state=GATED+verdict=clear → BLOCK (same semantics via cycle-state)
T17=$(make_project)
LOG17="$T17/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step1_test.md"
cat >"$LOG17" <<'MD'
## developer-phoenix-backend Section

## dev-gate Section

Gate ran but no ALL CLEAR marker written.
MD
write_cycle_state_fixture "$T17" "GATED" "$LOG17" "clear"
make_transcript "$T17/transcript.jsonl" "$LOG17"
out=$(make_input "$T17" false "" "$T17/transcript.jsonl" | bash "$HOOK" 2>/dev/null || true)
assert_contains "GATED+verdict=clear → BLOCK (cycle-state authoritative)" '"decision"' "$out"
rm -rf "$T17"

# ── Test 18: cycle-state=COMMITTED + step_log match → no block ───────────────
T18=$(make_project)
LOG18="$T18/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step1_test.md"
cat >"$LOG18" <<'MD'
## developer-phoenix-backend Section

## dev-gate Section

ALL CLEAR ✅

## reviewer-phoenix Section

QUALITY APPROVED ✅
MD
mkdir -p "$T18/codegen/gate-pending"
jq -n \
    --arg state "COMMITTED" \
    --arg step_log "$LOG18" \
    --arg session_id "test-18" \
    --arg verdict "" \
    --arg updated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{state:$state,step_log:$step_log,session_id:$session_id,verdict:$verdict,updated_at:$updated_at}' \
    >"$T18/codegen/gate-pending/cycle-state.json"
make_transcript "$T18/transcript.jsonl" "$LOG18"
out=$(make_input "$T18" false "" "$T18/transcript.jsonl" | bash "$HOOK" 2>/dev/null || true)
assert_not_contains "cycle-state=COMMITTED + step_log match → allow (fast-path)" '"decision"' "$out"
rm -rf "$T18"

# ── Test 19: cycle-state=REVIEWED + step_log match → BLOCK (curator not run) ─
T19=$(make_project)
LOG19="$T19/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step1_test.md"
cat >"$LOG19" <<'MD'
## reviewer-phoenix Section

QUALITY APPROVED ✅
MD
mkdir -p "$T19/codegen/gate-pending"
jq -n \
    --arg state "REVIEWED" \
    --arg step_log "$LOG19" \
    --arg session_id "test-19" \
    --arg verdict "" \
    --arg updated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{state:$state,step_log:$step_log,session_id:$session_id,verdict:$verdict,updated_at:$updated_at}' \
    >"$T19/codegen/gate-pending/cycle-state.json"
make_transcript "$T19/transcript.jsonl" "$LOG19"
out=$(make_input "$T19" false "" "$T19/transcript.jsonl" | bash "$HOOK" 2>/dev/null || true)
assert_contains "cycle-state=REVIEWED + step_log match → BLOCK (curator not run)" '"decision"' "$out"
rm -rf "$T19"

# ── Test 20: cycle-state=CURATED + step_log match → BLOCK (committer not run) ─
T20=$(make_project)
LOG20="$T20/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step1_test.md"
cat >"$LOG20" <<'MD'
## context-curator Section

Done.
MD
mkdir -p "$T20/codegen/gate-pending"
jq -n \
    --arg state "CURATED" \
    --arg step_log "$LOG20" \
    --arg session_id "test-20" \
    --arg verdict "" \
    --arg updated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{state:$state,step_log:$step_log,session_id:$session_id,verdict:$verdict,updated_at:$updated_at}' \
    >"$T20/codegen/gate-pending/cycle-state.json"
make_transcript "$T20/transcript.jsonl" "$LOG20"
out=$(make_input "$T20" false "" "$T20/transcript.jsonl" | bash "$HOOK" 2>/dev/null || true)
assert_contains "cycle-state=CURATED + step_log match → BLOCK (committer not run)" '"decision"' "$out"
rm -rf "$T20"

# ── Test 21: cycle-state=COMMITTED but step_log mismatch → fail-open (allow) ─
# Old: fell through to grep checks → BLOCK. New: no grep fallback → fail-open → no block.
T21=$(make_project)
LOG21="$T21/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step1_test.md"
cat >"$LOG21" <<'MD'
## developer-phoenix-backend Section

## dev-gate Section

ALL CLEAR ✅
MD
mkdir -p "$T21/codegen/gate-pending"
jq -n \
    --arg state "COMMITTED" \
    --arg step_log "/some/other/log.md" \
    --arg session_id "test-21" \
    --arg verdict "" \
    --arg updated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{state:$state,step_log:$step_log,session_id:$session_id,verdict:$verdict,updated_at:$updated_at}' \
    >"$T21/codegen/gate-pending/cycle-state.json"
make_transcript "$T21/transcript.jsonl" "$LOG21"
out=$(make_input "$T21" false "" "$T21/transcript.jsonl" | bash "$HOOK" 2>/dev/null || true)
# Mismatch → no cycle-state fast-path → no grep fallback → fail-open (allow)
assert_not_contains "cycle-state stale step_log mismatch → fail-open (no grep fallback)" '"decision"' "$out"
rm -rf "$T21"

# ── Test 22 REGRESSION: log has ## committer Section but cs_state=REVIEWED → BLOCK ──
# Header in log contradicts cycle-state; cycle-state wins → BLOCK.
T22=$(make_project)
LOG22="$T22/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step1_test.md"
cat >"$LOG22" <<'MD'
## developer-phoenix-backend Section

## dev-gate Section

ALL CLEAR ✅

## reviewer-phoenix Section

QUALITY APPROVED ✅

## committer Section

Committed (stale header, cycle-state contradicts).
MD
write_cycle_state_fixture "$T22" "REVIEWED" "$LOG22" ""
make_transcript "$T22/transcript.jsonl" "$LOG22"
out=$(make_input "$T22" false "" "$T22/transcript.jsonl" | bash "$HOOK" 2>/dev/null || true)
assert_contains "REGRESSION: committer header present but cs_state=REVIEWED → BLOCK (cycle-state wins)" '"decision"' "$out"
assert_contains "regression: block reason mentions context-curator" 'context-curator' "$out"
rm -rf "$T22"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
