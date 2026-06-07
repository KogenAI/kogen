#!/usr/bin/env bash
# stop-cycle-guard_test.sh — unit tests for stop-cycle-guard.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/stop-cycle-guard.sh"

pass=0
fail=0

# run_test desc expected_decision input_json transcript_content [log_content]
# expected_decision: "block" or "allow"
run_test() {
    local desc="$1"
    local expected="$2"
    local input_json="$3"
    local transcript_content="$4"
    local log_content="${5:-}"

    local tmp
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' RETURN

    # Write transcript fixture.
    printf '%s\n' "$transcript_content" >"$tmp/transcript.jsonl"

    # Write a session log if provided (simulates a stale prior-session log).
    if [ -n "$log_content" ]; then
        mkdir -p "$tmp/codegen/logging"
        printf '%s\n' "$log_content" >"$tmp/codegen/logging/test_session.md"
        # Touch it so -mmin -60 finds it.
        touch "$tmp/codegen/logging/test_session.md"
    fi

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

# Helper: build the stdin JSON for the hook.
# Usage: make_input <transcript_path> <cwd> <stop_hook_active> <last_message>
make_input() {
    local transcript_path="$1"
    local cwd="$2"
    local stop_hook_active="$3"
    local last_message="$4"
    printf '{"hook_event_name":"Stop","session_id":"test-sess","transcript_path":"%s","cwd":"%s","stop_hook_active":%s,"last_assistant_message":"%s"}' \
        "$transcript_path" "$cwd" "$stop_hook_active" "$last_message"
}

# Fixture helpers.
AGENT_ENTRY_DEVELOPER='{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Agent","input":{"subagent_type":"developer-phoenix-backend","description":"x","prompt":"x"}}]}}'
AGENT_ENTRY_COMMITTER='{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Agent","input":{"subagent_type":"committer","description":"x","prompt":"x"}}]}}'
AGENT_ENTRY_REVIEWER='{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Agent","input":{"subagent_type":"reviewer-phoenix","description":"x","prompt":"x"}}]}}'
EMPTY_TRANSCRIPT='{"type":"assistant","message":{"content":[{"type":"text","text":"Just some text, no Agent calls."}]}}'

STALE_LOG_WITH_DEVELOPER='# Session Log
## Delegation Timeline
| Time | Agent | Task | Result |
| ---- | ----- | ---- | ------ |
| 01:00 | developer-phoenix-backend | Implement feature | done |'

# --- Test 1: Original bug repro ---
# Empty transcript (no Agent entries) + stale log with developer-phoenix-backend → MUST allow.
tmp1=$(mktemp -d)
trap 'rm -rf "$tmp1"' EXIT
printf '%s\n' "$EMPTY_TRANSCRIPT" >"$tmp1/transcript.jsonl"
mkdir -p "$tmp1/codegen/logging"
printf '%s\n' "$STALE_LOG_WITH_DEVELOPER" >"$tmp1/codegen/logging/stale.md"
touch "$tmp1/codegen/logging/stale.md"
INPUT1=$(make_input "$tmp1/transcript.jsonl" "$tmp1" "false" "Done.")
run_test "no_agent_calls: empty transcript + stale log with developer → allow" \
    "allow" "$INPUT1" "$EMPTY_TRANSCRIPT"

# --- Test 2: Mid-cycle developer ---
# Transcript ending in developer-phoenix-backend → MUST block.
tmp2=$(mktemp -d)
printf '%s\n' "$AGENT_ENTRY_DEVELOPER" >"$tmp2/transcript.jsonl"
INPUT2=$(make_input "$tmp2/transcript.jsonl" "$tmp2" "false" "Done.")
run_test "mid_cycle_developer: transcript ends in developer-phoenix-backend → block" \
    "block" "$INPUT2" "$AGENT_ENTRY_DEVELOPER"

# --- Test 3: Cycle complete (committer) ---
# Transcript ending in committer → MUST allow.
tmp3=$(mktemp -d)
TRANSCRIPT3="${AGENT_ENTRY_DEVELOPER}
${AGENT_ENTRY_COMMITTER}"
printf '%s\n' "$TRANSCRIPT3" >"$tmp3/transcript.jsonl"
INPUT3=$(make_input "$tmp3/transcript.jsonl" "$tmp3" "false" "Done.")
run_test "cycle_complete_committer: transcript ends in committer → allow" \
    "allow" "$INPUT3" "$TRANSCRIPT3"

# --- Test 4: Mid-cycle reviewer-phoenix ---
# Transcript ending in reviewer-phoenix → MUST block.
tmp4=$(mktemp -d)
printf '%s\n' "$AGENT_ENTRY_REVIEWER" >"$tmp4/transcript.jsonl"
INPUT4=$(make_input "$tmp4/transcript.jsonl" "$tmp4" "false" "Done.")
run_test "mid_cycle_reviewer_phoenix: transcript ends in reviewer-phoenix → block" \
    "block" "$INPUT4" "$AGENT_ENTRY_REVIEWER"

# --- Test 5: Empty transcript_path (fallback) ---
# transcript_path is empty with mid-cycle log present → MUST allow.
tmp5=$(mktemp -d)
mkdir -p "$tmp5/codegen/logging"
printf '%s\n' "$STALE_LOG_WITH_DEVELOPER" >"$tmp5/codegen/logging/current.md"
touch "$tmp5/codegen/logging/current.md"
INPUT5=$(make_input "" "$tmp5" "false" "Done.")
run_test "empty_transcript_path: no transcript path → allow (safe fallback)" \
    "allow" "$INPUT5" ""

# --- Test 6: Intent guard wins ---
# Transcript ending in developer-phoenix-backend + message ends in "?" → MUST allow.
tmp6=$(mktemp -d)
printf '%s\n' "$AGENT_ENTRY_DEVELOPER" >"$tmp6/transcript.jsonl"
INPUT6=$(make_input "$tmp6/transcript.jsonl" "$tmp6" "false" "Should I continue?")
run_test "intent_guard_wins: question mark in last message → allow" \
    "allow" "$INPUT6" "$AGENT_ENTRY_DEVELOPER"

# --- Test 7: STOP_HOOK_ACTIVE wins ---
# stop_hook_active: true + mid-cycle transcript → MUST allow.
tmp7=$(mktemp -d)
printf '%s\n' "$AGENT_ENTRY_DEVELOPER" >"$tmp7/transcript.jsonl"
INPUT7=$(make_input "$tmp7/transcript.jsonl" "$tmp7" "true" "Done.")
run_test "stop_hook_active_wins: stop_hook_active=true → allow" \
    "allow" "$INPUT7" "$AGENT_ENTRY_DEVELOPER"

# --- Test 8: ScheduleWakeup guard ---
# Transcript ends in developer-phoenix-backend + last message contains "ScheduleWakeup" → MUST allow.
tmp8=$(mktemp -d)
printf '%s\n' "$AGENT_ENTRY_DEVELOPER" >"$tmp8/transcript.jsonl"
INPUT8=$(make_input "$tmp8/transcript.jsonl" "$tmp8" "false" "ScheduleWakeup called. Will check back once the gate finishes.")
run_test "schedulewakeup_guard: ScheduleWakeup in last message → allow" \
    "allow" "$INPUT8" "$AGENT_ENTRY_DEVELOPER"

# --- Test 9: async-wait guard ("still running") ---
# Transcript ends in developer + last message contains "still running" → MUST allow.
tmp9=$(mktemp -d)
printf '%s\n' "$AGENT_ENTRY_DEVELOPER" >"$tmp9/transcript.jsonl"
INPUT9=$(make_input "$tmp9/transcript.jsonl" "$tmp9" "false" "The gate is still running, will resume when done.")
run_test "async_wait_guard: still running in last message → allow" \
    "allow" "$INPUT9" "$AGENT_ENTRY_DEVELOPER"

# --- Test 10: Verdict guard — developer in transcript, session log exists but no verdict string → allow ---
# (Hook writes the dev-gate Section.)
tmp10=$(mktemp -d)
mkdir -p "$tmp10/codegen/logging"
printf '# Session Log\n## dev-gate Section\nDiagnosis: timeout.\n' \
    >"$tmp10/codegen/logging/test_session.md"
# Transcript must record the Write to the log so session_log_from_transcript finds it.
{
    printf '%s\n' "$AGENT_ENTRY_DEVELOPER"
    printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"%s/codegen/logging/test_session.md"}}]}}\n' "$tmp10"
} >"$tmp10/transcript.jsonl"
INPUT10=$(make_input "$tmp10/transcript.jsonl" "$tmp10" "false" "Done.")
run_test "verdict_guard_no_verdict: developer in transcript, log exists but no verdict → allow" \
    "allow" "$INPUT10" "$AGENT_ENTRY_DEVELOPER"

# --- Test 11: Verdict guard — developer in transcript, session log has ALL CLEAR → block ---
tmp11=$(mktemp -d)
mkdir -p "$tmp11/codegen/logging"
printf '# Session Log\n## dev-gate Section\nALL CLEAR ✅\n' \
    >"$tmp11/codegen/logging/test_session.md"
# Transcript must record the Write so session_log_from_transcript finds it.
{
    printf '%s\n' "$AGENT_ENTRY_DEVELOPER"
    printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"%s/codegen/logging/test_session.md"}}]}}\n' "$tmp11"
} >"$tmp11/transcript.jsonl"
INPUT11=$(make_input "$tmp11/transcript.jsonl" "$tmp11" "false" "Done.")
run_test "verdict_guard_with_verdict: developer in transcript, log has ALL CLEAR → block" \
    "block" "$INPUT11" "$AGENT_ENTRY_DEVELOPER"

# --- Test 12: A+B regression — A's transcript + B's newer log on disk → block reason cites A ---
# B's log has newer mtime; A's transcript records only A's log.
# Verdict guard must read A's log (which has ALL CLEAR) → block with A's path, not B's.
tmp12A=$(mktemp -d)
tmp12B=$(mktemp -d)
mkdir -p "$tmp12A/codegen/logging" "$tmp12B/codegen/logging"
LOG12A="$tmp12A/codegen/logging/A_session.md"
printf '# Session A\n## dev-gate Section\nALL CLEAR ✅\n' >"$LOG12A"
sleep 1
LOG12B="$tmp12B/codegen/logging/B_session.md"
printf '# Session B\n## dev-gate Section\nALL CLEAR ✅\n' >"$LOG12B"
# A's transcript records Write to A's log + developer agent call.
{
    printf '%s\n' "$AGENT_ENTRY_DEVELOPER"
    printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"%s"}}]}}\n' "$LOG12A"
} >"$tmp12A/transcript.jsonl"
INPUT12=$(make_input "$tmp12A/transcript.jsonl" "$tmp12A" "false" "Done.")
stdout12=$(printf '%s' "$INPUT12" | bash "$GUARD" 2>/dev/null || true)
# Must block (A's log has verdict) and reason must reference A's path, not B's.
if printf '%s' "$stdout12" | grep -q '"decision"[[:space:]]*:[[:space:]]*"block"' &&
    printf '%s' "$stdout12" | grep -qF "$LOG12A" &&
    ! printf '%s' "$stdout12" | grep -qF "$LOG12B"; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: A+B regression: block cites A log, not B\n'
    pass=$((pass + 1))
else
    printf 'FAIL: A+B regression: wrong block reason\n  stdout: %s\n' "$stdout12"
    fail=$((fail + 1))
fi
rm -rf "$tmp12A" "$tmp12B"

# --- Test 13: context-curator mid-cycle → BLOCK ---
# Transcript ending in context-curator with a session log containing ALL CLEAR → MUST block.
# Use a unique session_id to avoid counter-file exhaustion from earlier blocking tests.
tmp13=$(mktemp -d)
mkdir -p "$tmp13/codegen/logging"
printf '# Session Log\n## dev-gate Section\nALL CLEAR ✅\n' \
    >"$tmp13/codegen/logging/test_session.md"
# Remove any stale counter file for the unique session.
rm -f "/tmp/claude-cycle-guard-test-sess-13.count"
AGENT_ENTRY_CURATOR='{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Agent","input":{"subagent_type":"context-curator","description":"x","prompt":"x"}}]}}'
{
    printf '%s\n' "$AGENT_ENTRY_CURATOR"
    printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"%s/codegen/logging/test_session.md"}}]}}\n' "$tmp13"
} >"$tmp13/transcript.jsonl"
INPUT13=$(printf '{"hook_event_name":"Stop","session_id":"test-sess-13","transcript_path":"%s/transcript.jsonl","cwd":"%s","stop_hook_active":false,"last_assistant_message":"Done."}' "$tmp13" "$tmp13")
run_test "mid_cycle_context_curator: transcript ends in context-curator + ALL CLEAR → block" \
    "block" "$INPUT13" "$AGENT_ENTRY_CURATOR"
rm -rf "$tmp13"

# --- Test 14: committer is terminal → ALLOW ---
# Transcript ending in committer → MUST allow (not mid-cycle).
# This confirms the committer case is NOT in the mid-cycle blocker.
tmp14=$(mktemp -d)
TRANSCRIPT14="${AGENT_ENTRY_DEVELOPER}
${AGENT_ENTRY_COMMITTER}"
printf '%s\n' "$TRANSCRIPT14" >"$tmp14/transcript.jsonl"
INPUT14=$(make_input "$tmp14/transcript.jsonl" "$tmp14" "false" "Done.")
run_test "committer_terminal: transcript ends in committer → allow (cycle complete)" \
    "allow" "$INPUT14" "$TRANSCRIPT14"
rm -rf "$tmp14"

# ── Test 15: in-flight gate (live PID flag) → BLOCK ─────────────────────────
# When latest.flag exists and PID is alive, stop-cycle-guard must BLOCK
# regardless of transcript state.
tmp15=$(mktemp -d)
mkdir -p "$tmp15/codegen/gate-pending"
# Use own PID as a live PID
LIVE_PID_15=$$
NOW_ISO_15=$(date -u +%Y-%m-%dT%H:%M:%SZ)
cat >"$tmp15/codegen/gate-pending/${LIVE_PID_15}.flag" <<EOF
gate=make ci
pid=$LIVE_PID_15
log=$tmp15/gate.log
exitcode_file=$tmp15/gate.exitcode
started_at=$NOW_ISO_15
session_id=test-15
mode=long
status=running
EOF
rm -f "$tmp15/codegen/gate-pending/latest.flag"
ln -sf "$tmp15/codegen/gate-pending/${LIVE_PID_15}.flag" "$tmp15/codegen/gate-pending/latest.flag" 2>/dev/null ||
    cp "$tmp15/codegen/gate-pending/${LIVE_PID_15}.flag" "$tmp15/codegen/gate-pending/latest.flag"
printf '%s\n' "$AGENT_ENTRY_DEVELOPER" >"$tmp15/transcript.jsonl"
INPUT15=$(make_input "$tmp15/transcript.jsonl" "$tmp15" "false" "Done.")
run_test "inflight_gate_blocks: live PID flag present → BLOCK" \
    "block" "$INPUT15" "$AGENT_ENTRY_DEVELOPER"
rm -rf "$tmp15"

# ── Test 16: no-flag async-wait → ALLOW ─────────────────────────────────────
# When no flag is in flight, the existing async-wait escape still works.
tmp16=$(mktemp -d)
printf '%s\n' "$AGENT_ENTRY_DEVELOPER" >"$tmp16/transcript.jsonl"
INPUT16=$(make_input "$tmp16/transcript.jsonl" "$tmp16" "false" "ScheduleWakeup called. Will check back once gate finishes.")
run_test "no_flag_async_wait_allow: no flag + ScheduleWakeup → allow" \
    "allow" "$INPUT16" "$AGENT_ENTRY_DEVELOPER"
rm -rf "$tmp16"

# ── Test 17: dead-PID flag → not-in-flight → allow (falls through to other guards) ─
tmp17=$(mktemp -d)
mkdir -p "$tmp17/codegen/gate-pending"
# Dead PID
cat >"$tmp17/codegen/gate-pending/9999999.flag" <<EOF
gate=make ci
pid=9999999
log=$tmp17/gate.log
exitcode_file=$tmp17/gate.exitcode
started_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
session_id=test-17
mode=long
status=running
EOF
rm -f "$tmp17/codegen/gate-pending/latest.flag"
ln -sf "$tmp17/codegen/gate-pending/9999999.flag" "$tmp17/codegen/gate-pending/latest.flag" 2>/dev/null ||
    cp "$tmp17/codegen/gate-pending/9999999.flag" "$tmp17/codegen/gate-pending/latest.flag"
# No transcript → allow (no agent calls)
printf '{"type":"assistant","message":{"content":[{"type":"text","text":"Done."}]}}\n' >"$tmp17/transcript.jsonl"
INPUT17=$(make_input "$tmp17/transcript.jsonl" "$tmp17" "false" "Done.")
run_test "dead_pid_flag_not_inflight: dead PID flag → not in-flight → allow (no agents)" \
    "allow" "$INPUT17" '{"type":"assistant","message":{"content":[{"type":"text","text":"Done."}]}}'
rm -rf "$tmp17"

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
