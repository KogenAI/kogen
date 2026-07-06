#!/usr/bin/env bash
# stop-gate-failure-breaker_test.sh — unit tests for stop-gate-failure-breaker.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/stop-gate-failure-breaker.sh"

pass=0
fail=0

# run_test desc expected_decision input_json
# expected_decision: "block" or "allow"
run_test() {
    local desc="$1"
    local expected="$2"
    local input_json="$3"

    local stdout
    stdout=$(printf '%s' "$input_json" | bash "$GUARD" 2>/dev/null || true)

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

# Helper: build stdin JSON for SubagentStop.
# Sets cwd to the project_dir so session_log_from_transcript and
# gate_result_verdict resolve relative to the same fixture root.
make_input() {
    local agent_type="$1"
    local transcript_path="$2"
    local project_dir="$3"
    local session_id="${4:-test-breaker-sess}"
    local stop_hook_active="${5:-false}"
    printf '{"hook_event_name":"SubagentStop","agent_type":"%s","session_id":"%s","transcript_path":"%s","cwd":"%s","stop_hook_active":%s}' \
        "$agent_type" "$session_id" "$transcript_path" "$project_dir" "$stop_hook_active"
}

# Fixture: write a transcript JSONL whose last entry is a Write tool_use
# pointing at the given log path (so session_log_from_transcript resolves it).
make_transcript() {
    local log_path="$1"
    local transcript_file="$2"
    printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"%s","content":"x"}}]}}\n' \
        "$log_path" >"$transcript_file"
}

# Fixture: write a session log containing N 'FAILED ❌' lines.
make_session_log() {
    local log_file="$1"
    local n="$2"
    for _ in $(seq 1 "$n"); do
        printf 'FAILED ❌\n'
    done >"$log_file"
}

# Fixture: write a gate-result.json with the given verdict.
make_gate_result() {
    local project_dir="$1"
    local verdict="$2"
    mkdir -p "$project_dir/codegen/gate-pending"
    printf '{"verdict":"%s"}\n' "$verdict" >"$project_dir/codegen/gate-pending/gate-result.json"
}

# Pre-clean any stale gate-breaker counter files before tests.
rm -f /tmp/claude-gate-breaker-test-breaker-sess.count
rm -f /tmp/claude-gate-breaker-test-breaker-sess-cap.count
rm -f /tmp/claude-gate-breaker-test-breaker-sess-bad.count
rm -f /tmp/claude-gate-breaker-test-breaker-sess-3a.count
rm -f /tmp/claude-gate-breaker-test-breaker-sess-3b.count
rm -f /tmp/claude-gate-breaker-test-breaker-sess-5a.count
rm -f /tmp/claude-gate-breaker-test-breaker-sess-vite.count
rm -f /tmp/claude-gate-breaker-test-breaker-sess-incr.count

# --- Test 1: 2 FAILED + verdict=failed → ALLOW (below threshold) ---
tmp1=$(mktemp -d)
log1="$tmp1/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_test_cycle.jsonl"
mkdir -p "$tmp1/codegen/logging"
make_session_log "$log1" 2
make_gate_result "$tmp1" "failed"
make_transcript "$log1" "$tmp1/transcript.jsonl"
INPUT1=$(make_input "developer-phoenix-backend" "$tmp1/transcript.jsonl" "$tmp1")
run_test "2_failed_verdict_failed: below threshold → allow" "allow" "$INPUT1"
rm -rf "$tmp1"

# --- Test 2: 3 FAILED + verdict=failed → BLOCK (at threshold) ---
tmp2=$(mktemp -d)
log2="$tmp2/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_test_cycle.jsonl"
mkdir -p "$tmp2/codegen/logging"
make_session_log "$log2" 3
make_gate_result "$tmp2" "failed"
make_transcript "$log2" "$tmp2/transcript.jsonl"
rm -f "/tmp/claude-gate-breaker-test-breaker-sess-3a.count"
INPUT2=$(make_input "developer-phoenix-backend" "$tmp2/transcript.jsonl" "$tmp2" "test-breaker-sess-3a")
run_test "3_failed_verdict_failed: at threshold → block" "block" "$INPUT2"
rm -rf "$tmp2"
rm -f "/tmp/claude-gate-breaker-test-breaker-sess-3a.count"

# --- Test 3: 5 FAILED + verdict=failed → BLOCK (above threshold) ---
tmp3=$(mktemp -d)
log3="$tmp3/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_test_cycle.jsonl"
mkdir -p "$tmp3/codegen/logging"
make_session_log "$log3" 5
make_gate_result "$tmp3" "failed"
make_transcript "$log3" "$tmp3/transcript.jsonl"
rm -f "/tmp/claude-gate-breaker-test-breaker-sess-5a.count"
INPUT3=$(make_input "developer-phoenix-backend" "$tmp3/transcript.jsonl" "$tmp3" "test-breaker-sess-5a")
run_test "5_failed_verdict_failed: above threshold → block" "block" "$INPUT3"
rm -rf "$tmp3"
rm -f "/tmp/claude-gate-breaker-test-breaker-sess-5a.count"

# --- Test 4: 3 FAILED + verdict=clear → ALLOW (verdict guard: recovered) ---
tmp4=$(mktemp -d)
log4="$tmp4/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_test_cycle.jsonl"
mkdir -p "$tmp4/codegen/logging"
make_session_log "$log4" 3
make_gate_result "$tmp4" "clear"
make_transcript "$log4" "$tmp4/transcript.jsonl"
INPUT4=$(make_input "developer-phoenix-backend" "$tmp4/transcript.jsonl" "$tmp4")
run_test "3_failed_verdict_clear: verdict=clear → allow (recovered)" "allow" "$INPUT4"
rm -rf "$tmp4"

# --- Test 5: 3 FAILED + verdict=inconclusive → ALLOW (env flake) ---
tmp5=$(mktemp -d)
log5="$tmp5/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_test_cycle.jsonl"
mkdir -p "$tmp5/codegen/logging"
make_session_log "$log5" 3
make_gate_result "$tmp5" "inconclusive"
make_transcript "$log5" "$tmp5/transcript.jsonl"
INPUT5=$(make_input "developer-phoenix-backend" "$tmp5/transcript.jsonl" "$tmp5")
run_test "3_failed_verdict_inconclusive: verdict=inconclusive → allow (env flake)" "allow" "$INPUT5"
rm -rf "$tmp5"

# --- Test 6: 3 FAILED + NO gate-result.json → ALLOW (verdict absent) ---
tmp6=$(mktemp -d)
log6="$tmp6/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_test_cycle.jsonl"
mkdir -p "$tmp6/codegen/logging"
make_session_log "$log6" 3
# No gate-result.json created.
make_transcript "$log6" "$tmp6/transcript.jsonl"
INPUT6=$(make_input "developer-phoenix-backend" "$tmp6/transcript.jsonl" "$tmp6")
run_test "3_failed_no_gate_result: verdict absent → allow" "allow" "$INPUT6"
rm -rf "$tmp6"

# --- Test 7: non-developer AGENT_TYPE (reviewer-phoenix) → ALLOW (matcher skip) ---
tmp7=$(mktemp -d)
log7="$tmp7/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_test_cycle.jsonl"
mkdir -p "$tmp7/codegen/logging"
make_session_log "$log7" 5
make_gate_result "$tmp7" "failed"
make_transcript "$log7" "$tmp7/transcript.jsonl"
INPUT7=$(make_input "reviewer-phoenix" "$tmp7/transcript.jsonl" "$tmp7")
run_test "non_developer_agent_type: reviewer-phoenix → skip (allow)" "allow" "$INPUT7"
rm -rf "$tmp7"

# --- Test 8: STOP_HOOK_ACTIVE=true → ALLOW (loop guard) ---
tmp8=$(mktemp -d)
log8="$tmp8/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_test_cycle.jsonl"
mkdir -p "$tmp8/codegen/logging"
make_session_log "$log8" 5
make_gate_result "$tmp8" "failed"
make_transcript "$log8" "$tmp8/transcript.jsonl"
INPUT8=$(make_input "developer-phoenix-backend" "$tmp8/transcript.jsonl" "$tmp8" "test-breaker-sess" "true")
run_test "stop_hook_active: stop_hook_active=true → allow" "allow" "$INPUT8"
rm -rf "$tmp8"

# --- Test 9: missing transcript path → ALLOW (no log discoverable) ---
tmp9=$(mktemp -d)
make_gate_result "$tmp9" "failed"
INPUT9=$(make_input "developer-phoenix-backend" "/tmp/no-such-transcript-does-not-exist.jsonl" "$tmp9")
run_test "missing_transcript_path: nonexistent transcript → allow" "allow" "$INPUT9"
rm -rf "$tmp9"

# --- Test 10: 0 FAILED in log → ALLOW ---
tmp10=$(mktemp -d)
log10="$tmp10/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_test_cycle.jsonl"
mkdir -p "$tmp10/codegen/logging"
make_session_log "$log10" 0
make_gate_result "$tmp10" "failed"
make_transcript "$log10" "$tmp10/transcript.jsonl"
INPUT10=$(make_input "developer-phoenix-backend" "$tmp10/transcript.jsonl" "$tmp10")
run_test "0_failures: 0 FAILED lines in log → allow" "allow" "$INPUT10"
rm -rf "$tmp10"

# --- Test 11: cap release: counter=2 + 5 failures + verdict=failed → ALLOW (cap cleared) ---
tmp11=$(mktemp -d)
log11="$tmp11/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_test_cycle.jsonl"
mkdir -p "$tmp11/codegen/logging"
make_session_log "$log11" 5
make_gate_result "$tmp11" "failed"
make_transcript "$log11" "$tmp11/transcript.jsonl"
printf '%s\n%s' "$log11" "2" >"/tmp/claude-gate-breaker-test-breaker-sess-cap.count"
INPUT11=$(make_input "developer-phoenix-backend" "$tmp11/transcript.jsonl" "$tmp11" "test-breaker-sess-cap")
run_test "cap_release: block_count=2 → cap reached → allow (cap cleared)" "allow" "$INPUT11"
rm -rf "$tmp11"
rm -f "/tmp/claude-gate-breaker-test-breaker-sess-cap.count"

# --- Test 12: malformed counter (line2="bad") + 3 failures + verdict=failed → BLOCK (treated as 0) ---
tmp12=$(mktemp -d)
log12="$tmp12/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_test_cycle.jsonl"
mkdir -p "$tmp12/codegen/logging"
make_session_log "$log12" 3
make_gate_result "$tmp12" "failed"
make_transcript "$log12" "$tmp12/transcript.jsonl"
printf '%s\n%s' "$log12" "bad-value" >"/tmp/claude-gate-breaker-test-breaker-sess-bad.count"
INPUT12=$(make_input "developer-phoenix-backend" "$tmp12/transcript.jsonl" "$tmp12" "test-breaker-sess-bad")
run_test "malformed_counter: bad counter → treated as 0 → applies threshold (block)" "block" "$INPUT12"
rm -rf "$tmp12"
rm -f "/tmp/claude-gate-breaker-test-breaker-sess-bad.count"

# --- Test 13: block increments counter — 1st block writes step_log\n1 (two-line) ---
tmp13=$(mktemp -d)
log13="$tmp13/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_test_cycle.jsonl"
mkdir -p "$tmp13/codegen/logging"
make_session_log "$log13" 3
make_gate_result "$tmp13" "failed"
make_transcript "$log13" "$tmp13/transcript.jsonl"
rm -f "/tmp/claude-gate-breaker-test-breaker-sess-incr.count"
INPUT13=$(make_input "developer-phoenix-backend" "$tmp13/transcript.jsonl" "$tmp13" "test-breaker-sess-incr")
stdout13=$(printf '%s' "$INPUT13" | bash "$GUARD" 2>/dev/null || true)
counter_line2=""
if [ -r "/tmp/claude-gate-breaker-test-breaker-sess-incr.count" ]; then
    counter_line2=$(sed -n '2p' "/tmp/claude-gate-breaker-test-breaker-sess-incr.count" 2>/dev/null || echo "")
fi
if printf '%s' "$stdout13" | grep -q '"decision"[[:space:]]*:[[:space:]]*"block"' && [ "$counter_line2" = "1" ]; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: block_increments_counter: 1st block writes step_log\n1\n'
    pass=$((pass + 1))
else
    printf 'FAIL: block_increments_counter — expected block + counter_line2=1, got stdout=%s counter_line2=%s\n' \
        "$stdout13" "$counter_line2"
    fail=$((fail + 1))
fi
rm -rf "$tmp13"
rm -f "/tmp/claude-gate-breaker-test-breaker-sess-incr.count"

# --- Test 14: developer-static + 3 FAILED + verdict=failed → BLOCK (broad matcher) ---
tmp14=$(mktemp -d)
log14="$tmp14/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_test_cycle.jsonl"
mkdir -p "$tmp14/codegen/logging"
make_session_log "$log14" 3
make_gate_result "$tmp14" "failed"
make_transcript "$log14" "$tmp14/transcript.jsonl"
rm -f "/tmp/claude-gate-breaker-test-breaker-sess-vite.count"
INPUT14=$(make_input "developer-static" "$tmp14/transcript.jsonl" "$tmp14" "test-breaker-sess-vite")
run_test "developer_static_broad_matcher: developer-static + 3 failures + verdict=failed → block" "block" "$INPUT14"
rm -rf "$tmp14"
rm -f "/tmp/claude-gate-breaker-test-breaker-sess-vite.count"

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
