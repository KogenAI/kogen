#!/usr/bin/env bash
# curator-before-committer_test.sh — unit tests for curator-before-committer.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/curator-before-committer.sh"

pass=0
fail=0

assert_deny() {
    local desc="$1"
    local stdout="$2"
    if printf '%s' "$stdout" | grep -q '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"'; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s — expected deny\n  stdout: %s\n' "$desc" "$stdout"
        fail=$((fail + 1))
    fi
}

assert_allow() {
    local desc="$1"
    local stdout="$2"
    if printf '%s' "$stdout" | grep -q '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"'; then
        printf 'FAIL: %s — expected allow, got deny\n  stdout: %s\n' "$desc" "$stdout"
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

make_transcript() {
    local transcript_path="$1"
    local log_path="$2"
    printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"%s"}}]}}\n' \
        "$log_path" >"$transcript_path"
}

mk_agent_input() {
    local stype="$1"
    local transcript_path="$2"
    local cwd="${3:-}"
    jq -n \
        --arg s "$stype" \
        --arg t "$transcript_path" \
        --arg cwd "$cwd" \
        '{"hook_event_name":"PreToolUse","tool_name":"Agent","tool_input":{"subagent_type":$s,"description":"x","prompt":"y"},"agent_id":"","agent_type":"","transcript_path":$t,"cwd":$cwd}'
}

write_cycle_state_fixture() {
    local dir="$1"
    local state="$2"
    local step_log="$3"
    mkdir -p "$dir/codegen/gate-pending"
    jq -n \
        --arg state "$state" \
        --arg step_log "$step_log" \
        --arg session_id "test-session" \
        --arg verdict "" \
        --arg updated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{state:$state,step_log:$step_log,session_id:$session_id,verdict:$verdict,updated_at:$updated_at}' \
        >"$dir/codegen/gate-pending/cycle-state.json"
}

# ── Test 1: committer blocked when cycle-state=REVIEWED ─────────────────────
T1=$(make_project)
LOG1="$T1/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_test_cycle.jsonl"
cat >"$LOG1" <<'MD'
## developer-phoenix-backend Section

result here

## dev-gate Section

ALL CLEAR ✅

## reviewer-phoenix Section

**Verdict**: QUALITY APPROVED ✅
MD
write_cycle_state_fixture "$T1" "REVIEWED" "$LOG1"
make_transcript "$T1/transcript.jsonl" "$LOG1"
out1=$(mk_agent_input "committer" "$T1/transcript.jsonl" "$T1" | bash "$HOOK" 2>/dev/null || true)
assert_deny "committer blocked: cycle-state=REVIEWED" "$out1"
rm -rf "$T1"

# ── Test 2: committer allowed when cycle-state=CURATED ──────────────────────
T2=$(make_project)
LOG2="$T2/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_test_cycle.jsonl"
cat >"$LOG2" <<'MD'
## developer-phoenix-backend Section

result here

## dev-gate Section

ALL CLEAR ✅

## reviewer-phoenix Section

**Verdict**: QUALITY APPROVED ✅

## context-curator Section

Files updated.
MD
write_cycle_state_fixture "$T2" "CURATED" "$LOG2"
make_transcript "$T2/transcript.jsonl" "$LOG2"
out2=$(mk_agent_input "committer" "$T2/transcript.jsonl" "$T2" | bash "$HOOK" 2>/dev/null || true)
assert_allow "committer allowed: cycle-state=CURATED (curator ran)" "$out2"
rm -rf "$T2"

# ── Test 3: non-committer subagents allowed unconditionally ─────────────────
T3=$(make_project)
LOG3="$T3/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_test_cycle.jsonl"
cat >"$LOG3" <<'MD'
## developer-phoenix-backend Section

result here

## dev-gate Section

ALL CLEAR ✅

## reviewer-phoenix Section

**Verdict**: QUALITY APPROVED ✅
MD
write_cycle_state_fixture "$T3" "REVIEWED" "$LOG3"
make_transcript "$T3/transcript.jsonl" "$LOG3"

for stype in "planner-phoenix" "developer-phoenix-backend" "reviewer-phoenix" "context-curator"; do
    out_s=$(mk_agent_input "$stype" "$T3/transcript.jsonl" "$T3" | bash "$HOOK" 2>/dev/null || true)
    assert_allow "$stype allowed unconditionally (not committer)" "$out_s"
done
rm -rf "$T3"

# ── Test 4: allow when log is missing (fail-open) ───────────────────────────
T4=$(make_project)
# No log file created; transcript references a non-existent log
FAKE_LOG="$T4/codegen/logging/nonexistent.jsonl"
make_transcript "$T4/transcript.jsonl" "$FAKE_LOG"
out4=$(mk_agent_input "committer" "$T4/transcript.jsonl" "$T4" | bash "$HOOK" 2>/dev/null || true)
assert_allow "committer allowed: no log file (fail-open)" "$out4"
rm -rf "$T4"

# ── Test 5 REGRESSION: context-curator Section present but cs_state=REVIEWED → DENY ──
# Log header suggests curator ran; cycle-state says REVIEWED (curator NOT run).
# Cycle-state wins → DENY.
T5=$(make_project)
LOG5="$T5/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_test_cycle.jsonl"
cat >"$LOG5" <<'MD'
## developer-phoenix-backend Section

result here

## reviewer-phoenix Section

**Verdict**: QUALITY APPROVED ✅

## context-curator Section

Stale header — curator did not actually complete.
MD
write_cycle_state_fixture "$T5" "REVIEWED" "$LOG5"
make_transcript "$T5/transcript.jsonl" "$LOG5"
out5=$(mk_agent_input "committer" "$T5/transcript.jsonl" "$T5" | bash "$HOOK" 2>/dev/null || true)
assert_deny "REGRESSION: context-curator Section present but cs_state=REVIEWED → DENY (cycle-state wins)" "$out5"
rm -rf "$T5"

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
