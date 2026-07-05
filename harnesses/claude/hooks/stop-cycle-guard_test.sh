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
# Usage: make_input <transcript_path> <cwd> <stop_hook_active> <last_message> [session_id]
make_input() {
    local transcript_path="$1"
    local cwd="$2"
    local stop_hook_active="$3"
    local last_message="$4"
    local session_id="${5:-test-sess}"
    printf '{"hook_event_name":"Stop","session_id":"%s","transcript_path":"%s","cwd":"%s","stop_hook_active":%s,"last_assistant_message":"%s"}' \
        "$session_id" "$transcript_path" "$cwd" "$stop_hook_active" "$last_message"
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
rm -f "/tmp/claude-cycle-guard-test-sess-2.count"
tmp2=$(mktemp -d)
printf '%s\n' "$AGENT_ENTRY_DEVELOPER" >"$tmp2/transcript.jsonl"
INPUT2=$(make_input "$tmp2/transcript.jsonl" "$tmp2" "false" "Done." "test-sess-2")
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
rm -f "/tmp/claude-cycle-guard-test-sess-4.count"
tmp4=$(mktemp -d)
printf '%s\n' "$AGENT_ENTRY_REVIEWER" >"$tmp4/transcript.jsonl"
INPUT4=$(make_input "$tmp4/transcript.jsonl" "$tmp4" "false" "Done." "test-sess-4")
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
# Use env -u to simulate interactive context (unset headless env if present).
tmp6=$(mktemp -d)
printf '%s\n' "$AGENT_ENTRY_DEVELOPER" >"$tmp6/transcript.jsonl"
INPUT6=$(make_input "$tmp6/transcript.jsonl" "$tmp6" "false" "Should I continue?")
stdout6=$(printf '%s' "$INPUT6" | env -u CODEGEN_BUILD_NON_INTERACTIVE bash "$GUARD" 2>/dev/null || true)
if ! printf '%s' "$stdout6" | grep -q '"decision"[[:space:]]*:[[:space:]]*"block"'; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: intent_guard_wins: question mark in last message → allow\n'
    pass=$((pass + 1))
else
    printf 'FAIL: intent_guard_wins: question mark in last message → allow — expected allow, got block\n  stdout: %s\n' "$stdout6"
    fail=$((fail + 1))
fi

# --- Test 7: STOP_HOOK_ACTIVE wins ---
# stop_hook_active: true + mid-cycle transcript → MUST allow.
tmp7=$(mktemp -d)
printf '%s\n' "$AGENT_ENTRY_DEVELOPER" >"$tmp7/transcript.jsonl"
INPUT7=$(make_input "$tmp7/transcript.jsonl" "$tmp7" "true" "Done.")
run_test "stop_hook_active_wins: stop_hook_active=true → allow" \
    "allow" "$INPUT7" "$AGENT_ENTRY_DEVELOPER"

# --- Test 8: ScheduleWakeup tool_use in transcript → ALLOW ---
# Transcript ends in developer-phoenix-backend + ScheduleWakeup tool_use entry → MUST allow.
# The guard keys on the tool-call record, not prose.
tmp8=$(mktemp -d)
SCHEDULE_WAKEUP_ENTRY='{"type":"assistant","message":{"content":[{"type":"tool_use","name":"ScheduleWakeup","input":{"delay_seconds":60}}]}}'
printf '%s\n%s\n' "$AGENT_ENTRY_DEVELOPER" "$SCHEDULE_WAKEUP_ENTRY" >"$tmp8/transcript.jsonl"
INPUT8=$(make_input "$tmp8/transcript.jsonl" "$tmp8" "false" "Gate still running, scheduled wakeup.")
run_test "schedulewakeup_tool_use: ScheduleWakeup tool_use in transcript → allow" \
    "allow" "$INPUT8" "$AGENT_ENTRY_DEVELOPER"

# --- Test 9: async-wait prose without ScheduleWakeup tool_use → BLOCK ---
# "still running" prose alone is no longer sufficient — requires a real tool call.
rm -f "/tmp/claude-cycle-guard-test-sess-9.count"
tmp9=$(mktemp -d)
printf '%s\n' "$AGENT_ENTRY_DEVELOPER" >"$tmp9/transcript.jsonl"
INPUT9=$(make_input "$tmp9/transcript.jsonl" "$tmp9" "false" "The gate is still running, will resume when done." "test-sess-9")
run_test "async_wait_prose_no_tool_use: still running prose without ScheduleWakeup tool_use → block" \
    "block" "$INPUT9" "$AGENT_ENTRY_DEVELOPER"

# --- Test 10a: Developer + no verdict + no gate-result.json → BLOCK ---
# VE never ran: developer finished, session log has no emoji verdict, no gate-result.json.
# Previously this allowed the stop — now it BLOCKS.
# Uses unique session_id to avoid cap exhaustion from earlier blocking tests.
rm -f "/tmp/claude-cycle-guard-test-sess-10a.count"
tmp10=$(mktemp -d)
mkdir -p "$tmp10/codegen/logging"
printf '# Session Log\n## dev-gate Section\nDiagnosis: timeout.\n' \
    >"$tmp10/codegen/logging/test_session.md"
# Transcript must record the Write to the log so session_log_from_transcript finds it.
{
    printf '%s\n' "$AGENT_ENTRY_DEVELOPER"
    printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"%s/codegen/logging/test_session.md"}}]}}\n' "$tmp10"
} >"$tmp10/transcript.jsonl"
INPUT10=$(printf '{"hook_event_name":"Stop","session_id":"test-sess-10a","transcript_path":"%s/transcript.jsonl","cwd":"%s","stop_hook_active":false,"last_assistant_message":"Done."}' "$tmp10" "$tmp10")
run_test "verdict_guard_developer_no_verdict_no_gate_result: developer ran, no verdict, no gate-result.json → block" \
    "block" "$INPUT10" "$AGENT_ENTRY_DEVELOPER"
rm -rf "$tmp10"

# --- Test 10b: Reviewer + no verdict → ALLOW ---
# reviewer-* with no emoji verdict: VE may have been blocked/INCONCLUSIVE — still allow.
tmp10b=$(mktemp -d)
mkdir -p "$tmp10b/codegen/logging"
printf '# Session Log\n## reviewer-phoenix Section\nReview complete.\n' \
    >"$tmp10b/codegen/logging/test_session.md"
{
    printf '%s\n' "$AGENT_ENTRY_REVIEWER"
    printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"%s/codegen/logging/test_session.md"}}]}}\n' "$tmp10b"
} >"$tmp10b/transcript.jsonl"
INPUT10b=$(printf '{"hook_event_name":"Stop","session_id":"test-sess-10b","transcript_path":"%s/transcript.jsonl","cwd":"%s","stop_hook_active":false,"last_assistant_message":"Done."}' "$tmp10b" "$tmp10b")
run_test "verdict_guard_reviewer_no_verdict: reviewer ran, no verdict → allow" \
    "allow" "$INPUT10b" "$AGENT_ENTRY_REVIEWER"
rm -rf "$tmp10b"

# --- Test 11: Verdict guard — developer in transcript, session log has ALL CLEAR → block ---
rm -f "/tmp/claude-cycle-guard-test-sess-11.count"
tmp11=$(mktemp -d)
mkdir -p "$tmp11/codegen/logging"
printf '# Session Log\n## dev-gate Section\nALL CLEAR ✅\n' \
    >"$tmp11/codegen/logging/test_session.md"
# Transcript must record the Write so session_log_from_transcript finds it.
{
    printf '%s\n' "$AGENT_ENTRY_DEVELOPER"
    printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"%s/codegen/logging/test_session.md"}}]}}\n' "$tmp11"
} >"$tmp11/transcript.jsonl"
INPUT11=$(make_input "$tmp11/transcript.jsonl" "$tmp11" "false" "Done." "test-sess-11")
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
rm -f "/tmp/claude-cycle-guard-test-sess-12.count"
INPUT12=$(make_input "$tmp12A/transcript.jsonl" "$tmp12A" "false" "Done." "test-sess-12")
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
rm -f "/tmp/claude-cycle-guard-test-sess-15.count"
INPUT15=$(make_input "$tmp15/transcript.jsonl" "$tmp15" "false" "Done." "test-sess-15")
run_test "inflight_gate_blocks: live PID flag present → BLOCK" \
    "block" "$INPUT15" "$AGENT_ENTRY_DEVELOPER"
rm -rf "$tmp15"

# ── Test 16: no-flag async-wait with ScheduleWakeup tool_use → ALLOW ────────
# When no flag is in flight + ScheduleWakeup tool_use exists in transcript → allow.
tmp16=$(mktemp -d)
SCHEDULE_WAKEUP_ENTRY16='{"type":"assistant","message":{"content":[{"type":"tool_use","name":"ScheduleWakeup","input":{"delay_seconds":60}}]}}'
printf '%s\n%s\n' "$AGENT_ENTRY_DEVELOPER" "$SCHEDULE_WAKEUP_ENTRY16" >"$tmp16/transcript.jsonl"
INPUT16=$(make_input "$tmp16/transcript.jsonl" "$tmp16" "false" "ScheduleWakeup called. Will check back once gate finishes.")
run_test "no_flag_async_wait_allow: no flag + ScheduleWakeup tool_use → allow" \
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

# ── Test 18: bare "Blocked" keyword in last message + developer → BLOCK ──────
# The intent guard no longer grants escape on "Blocked" substring — only trailing "?" counts.
rm -f "/tmp/claude-cycle-guard-test-sess-18.count"
tmp18=$(mktemp -d)
printf '%s\n' "$AGENT_ENTRY_DEVELOPER" >"$tmp18/transcript.jsonl"
INPUT18=$(make_input "$tmp18/transcript.jsonl" "$tmp18" "false" "I am Blocked on this task." "test-sess-18")
run_test "bare_blocked_keyword_blocks: Blocked keyword alone no longer escapes intent guard → block" \
    "block" "$INPUT18" "$AGENT_ENTRY_DEVELOPER"
rm -rf "$tmp18"

# ── Test 19: developer + gate-result.json inconclusive → BLOCK ───────────────
# gate-result.json says inconclusive → gate did not confirm clear → BLOCK (not "never ran" carve-out).
# gate_result_verdict reads from <project_dir>/codegen/gate-pending/gate-result.json
rm -f "/tmp/claude-cycle-guard-test-sess-19.count"
tmp19=$(mktemp -d)
mkdir -p "$tmp19/codegen/logging" "$tmp19/codegen/gate-pending"
printf '# Session Log\n## dev-gate Section\nDiagnosis: pool exhausted.\n' \
    >"$tmp19/codegen/logging/test_session.md"
printf '{"verdict":"inconclusive","gate":"make test","mode":"short"}\n' \
    >"$tmp19/codegen/gate-pending/gate-result.json"
{
    printf '%s\n' "$AGENT_ENTRY_DEVELOPER"
    printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"%s/codegen/logging/test_session.md"}}]}}\n' "$tmp19"
} >"$tmp19/transcript.jsonl"
INPUT19=$(make_input "$tmp19/transcript.jsonl" "$tmp19" "false" "Done." "test-sess-19")
run_test "developer_gate_result_inconclusive: developer + gate-result=inconclusive → BLOCK (gate did not confirm clear)" \
    "block" "$INPUT19" "$AGENT_ENTRY_DEVELOPER"
rm -rf "$tmp19"

# --- Test 20: Gate=clear + dirty tree → BLOCK with "tree is dirty" reason ---
rm -f "/tmp/claude-cycle-guard-test-sess-20.count"
tmp20=$(mktemp -d)
mkdir -p "$tmp20/codegen/logging" "$tmp20/codegen/gate-pending"
printf '# Session Log\n## dev-gate Section\nALL CLEAR ✅\n' \
    >"$tmp20/codegen/logging/test_session.md"
printf '{"verdict":"clear","gate":"make test","mode":"short"}\n' \
    >"$tmp20/codegen/gate-pending/gate-result.json"
# Init a real git repo so git status --porcelain works.
git -C "$tmp20" init -q 2>/dev/null
# Add an untracked file to make the tree dirty.
printf 'dirty\n' >"$tmp20/untracked-file.txt"
{
    printf '%s\n' "$AGENT_ENTRY_DEVELOPER"
    printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"%s/codegen/logging/test_session.md"}}]}}\n' "$tmp20"
} >"$tmp20/transcript.jsonl"
INPUT20=$(make_input "$tmp20/transcript.jsonl" "$tmp20" "false" "Done." "test-sess-20")
stdout20=$(printf '%s' "$INPUT20" | bash "$GUARD" 2>/dev/null || true)
if printf '%s' "$stdout20" | grep -q '"decision"[[:space:]]*:[[:space:]]*"block"' &&
    printf '%s' "$stdout20" | grep -q 'tree is dirty'; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: dirty_tree_gate_clear: gate=clear + dirty tree → block with dirty-tree reason\n'
    pass=$((pass + 1))
else
    printf 'FAIL: dirty_tree_gate_clear: expected block with "tree is dirty" in reason\n  stdout: %s\n' "$stdout20"
    fail=$((fail + 1))
fi
rm -rf "$tmp20"

# --- Test 21: Gate=clear + clean tree → BLOCK for mid-cycle reason (NOT dirty-tree) ---
rm -f "/tmp/claude-cycle-guard-test-sess-21.count"
tmp21=$(mktemp -d)
mkdir -p "$tmp21/codegen/logging" "$tmp21/codegen/gate-pending"
printf '# Session Log\n## dev-gate Section\nALL CLEAR ✅\n' \
    >"$tmp21/codegen/logging/test_session.md"
printf '{"verdict":"clear","gate":"make test","mode":"short"}\n' \
    >"$tmp21/codegen/gate-pending/gate-result.json"
# Init a real git repo and commit all fixture files so the tree is clean.
git -C "$tmp21" init -q 2>/dev/null
git -C "$tmp21" config user.email "test@test.com" 2>/dev/null
git -C "$tmp21" config user.name "Test" 2>/dev/null
git -C "$tmp21" add -A 2>/dev/null
git -C "$tmp21" commit -q -m "fixture" 2>/dev/null
# Write transcript AFTER commit so it's a new untracked file — but then add+commit it too.
{
    printf '%s\n' "$AGENT_ENTRY_DEVELOPER"
    printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"%s/codegen/logging/test_session.md"}}]}}\n' "$tmp21"
} >"$tmp21/transcript.jsonl"
git -C "$tmp21" add -A 2>/dev/null
git -C "$tmp21" commit -q -m "transcript" 2>/dev/null
INPUT21=$(make_input "$tmp21/transcript.jsonl" "$tmp21" "false" "Done." "test-sess-21")
stdout21=$(printf '%s' "$INPUT21" | bash "$GUARD" 2>/dev/null || true)
if printf '%s' "$stdout21" | grep -q '"decision"[[:space:]]*:[[:space:]]*"block"' &&
    ! printf '%s' "$stdout21" | grep -q 'tree is dirty'; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: clean_tree_gate_clear: gate=clear + clean tree → block (mid-cycle), no dirty-tree reason\n'
    pass=$((pass + 1))
else
    printf 'FAIL: clean_tree_gate_clear: expected block without "tree is dirty" in reason\n  stdout: %s\n' "$stdout21"
    fail=$((fail + 1))
fi
rm -rf "$tmp21"

# ── Test 22: reviewer + gate-result.json inconclusive → BLOCK ────────────────
# Inconclusive is no longer a permitted stop for ANY role — gate did not confirm clear.
rm -f "/tmp/claude-cycle-guard-test-sess-22.count"
tmp22=$(mktemp -d)
mkdir -p "$tmp22/codegen/logging" "$tmp22/codegen/gate-pending"
printf '# Session Log\n## reviewer-phoenix Section\nReview complete.\n' \
    >"$tmp22/codegen/logging/test_session.md"
printf '{"verdict":"inconclusive","gate":"make test","mode":"short"}\n' \
    >"$tmp22/codegen/gate-pending/gate-result.json"
{
    printf '%s\n' "$AGENT_ENTRY_REVIEWER"
    printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"%s/codegen/logging/test_session.md"}}]}}\n' "$tmp22"
} >"$tmp22/transcript.jsonl"
INPUT22=$(make_input "$tmp22/transcript.jsonl" "$tmp22" "false" "Done." "test-sess-22")
run_test "reviewer_gate_result_inconclusive: reviewer + gate-result=inconclusive → block" \
    "block" "$INPUT22" "$AGENT_ENTRY_REVIEWER"
rm -rf "$tmp22"

# ── Test 23: per-step cap — step-A exhausted, stop on step-B resets budget ───
# Step-A counter is at cap (2). Guard fires with a transcript pointing to step-B.
# Expected: step-B is a new step → count resets to 0 → BLOCK (first block on B).
rm -f "/tmp/claude-cycle-guard-test-sess-23.count"
tmp23A=$(mktemp -d)
tmp23B=$(mktemp -d)
mkdir -p "$tmp23A/codegen/logging" "$tmp23B/codegen/logging"
LOG23A="$tmp23A/codegen/logging/A_session.md"
LOG23B="$tmp23B/codegen/logging/B_session.md"
printf '# Session A\n## dev-gate Section\nALL CLEAR ✅\n' >"$LOG23A"
printf '# Session B\n## dev-gate Section\nALL CLEAR ✅\n' >"$LOG23B"
# Pre-seed counter scoped to step-A at cap.
printf '%s\n2\n' "$LOG23A" >"/tmp/claude-cycle-guard-test-sess-23.count"
# Transcript for step-B session: developer agent + Write to B's log.
{
    printf '%s\n' "$AGENT_ENTRY_DEVELOPER"
    printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"%s"}}]}}\n' "$LOG23B"
} >"$tmp23B/transcript.jsonl"
INPUT23=$(make_input "$tmp23B/transcript.jsonl" "$tmp23B" "false" "Done." "test-sess-23")
run_test "per_step_cap_step_b_after_a_exhausted: step-A at cap, stop on step-B resets budget → block" \
    "block" "$INPUT23" "$AGENT_ENTRY_DEVELOPER"
rm -rf "$tmp23A" "$tmp23B"
rm -f "/tmp/claude-cycle-guard-test-sess-23.count"

# ── Test 24: empty resolver keeps scope — in-progress count NOT reset ─────────
# Counter is at count=1 for step-A. Transcript has developer agent but NO Write
# to any codegen/logging/*.md (resolver returns empty). Expected: still BLOCK
# (count=1 < cap; empty resolver did NOT collapse to global / did NOT reset).
rm -f "/tmp/claude-cycle-guard-test-sess-24.count"
tmp24=$(mktemp -d)
LOG24="$tmp24/codegen/logging/cur_session.md"
mkdir -p "$tmp24/codegen/logging"
printf '# Session\n## dev-gate Section\nALL CLEAR ✅\n' >"$LOG24"
# Pre-seed counter scoped to cur_session.md, count=1.
printf '%s\n1\n' "$LOG24" >"/tmp/claude-cycle-guard-test-sess-24.count"
# Transcript has developer agent but NO Write to codegen/logging → resolver returns empty.
{
    printf '%s\n' "$AGENT_ENTRY_DEVELOPER"
} >"$tmp24/transcript.jsonl"
INPUT24=$(make_input "$tmp24/transcript.jsonl" "$tmp24" "false" "Done." "test-sess-24")
run_test "empty_resolver_keeps_scope: resolver empty, count=1 on step-A → still block (no reset)" \
    "block" "$INPUT24" "$AGENT_ENTRY_DEVELOPER"
rm -rf "$tmp24"
rm -f "/tmp/claude-cycle-guard-test-sess-24.count"

# ── Test 25: cycle-state=COMMITTED → allow (fast-path) ───────────────────────
# cycle-state.json step_log matches active log + state=COMMITTED → allow immediately.
tmp25=$(mktemp -d)
mkdir -p "$tmp25/codegen/logging" "$tmp25/codegen/gate-pending"
LOG25="$tmp25/codegen/logging/20260614_step1_feat.md"
printf '# Session\n## committer Section\n\nCommitted.\n' >"$LOG25"
jq -n \
    --arg state "COMMITTED" \
    --arg step_log "$LOG25" \
    --arg session_id "test-sess-25" \
    --arg verdict "" \
    --arg updated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{state:$state,step_log:$step_log,session_id:$session_id,verdict:$verdict,updated_at:$updated_at}' \
    >"$tmp25/codegen/gate-pending/cycle-state.json"
{
    printf '%s\n' "$AGENT_ENTRY_DEVELOPER"
    printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"%s"}}]}}\n' "$LOG25"
} >"$tmp25/transcript.jsonl"
INPUT25=$(make_input "$tmp25/transcript.jsonl" "$tmp25" "false" "Done." "test-sess-25")
run_test "cycle_state_committed_allows: cycle-state=COMMITTED + step_log match → allow" \
    "allow" "$INPUT25" "$AGENT_ENTRY_DEVELOPER"
rm -rf "$tmp25"

# ── Test 26: cycle-state=COMMITTED but step_log mismatch → fall-through → block ─
# cycle-state.json belongs to a different step log → authoritative, but mismatch → fall-through.
rm -f "/tmp/claude-cycle-guard-test-sess-26.count"
tmp26=$(mktemp -d)
mkdir -p "$tmp26/codegen/logging" "$tmp26/codegen/gate-pending"
LOG26_ACTIVE="$tmp26/codegen/logging/20260614_step1_feat.md"
LOG26_OTHER="$tmp26/codegen/logging/20260614_step2_other.md"
printf '# Session\n## dev-gate Section\nALL CLEAR ✅\n' >"$LOG26_ACTIVE"
# cycle-state references a different log → mismatch → fall-through → standard logic blocks
jq -n \
    --arg state "COMMITTED" \
    --arg step_log "$LOG26_OTHER" \
    --arg session_id "test-sess-26" \
    --arg verdict "" \
    --arg updated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{state:$state,step_log:$step_log,session_id:$session_id,verdict:$verdict,updated_at:$updated_at}' \
    >"$tmp26/codegen/gate-pending/cycle-state.json"
{
    printf '%s\n' "$AGENT_ENTRY_DEVELOPER"
    printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"%s"}}]}}\n' "$LOG26_ACTIVE"
} >"$tmp26/transcript.jsonl"
INPUT26=$(make_input "$tmp26/transcript.jsonl" "$tmp26" "false" "Done." "test-sess-26")
run_test "cycle_state_stale_step_log_falls_through: COMMITTED but step_log mismatch → fall-through → block" \
    "block" "$INPUT26" "$AGENT_ENTRY_DEVELOPER"
rm -rf "$tmp26"
rm -f "/tmp/claude-cycle-guard-test-sess-26.count"

# ── Test 27: CODEGEN_BUILD_NON_INTERACTIVE suppresses intent escape → BLOCK ───
# Headless build: transcript ends in developer-phoenix-backend + last message "?"
# → intent escape must NOT fire → guard blocks.
rm -f "/tmp/claude-cycle-guard-test-sess-headless-scg.count"
tmp27=$(mktemp -d)
printf '%s\n' "$AGENT_ENTRY_DEVELOPER" >"$tmp27/transcript.jsonl"
INPUT27=$(make_input "$tmp27/transcript.jsonl" "$tmp27" "false" "Should I continue?" "test-sess-headless-scg")
stdout27=$(printf '%s' "$INPUT27" | CODEGEN_BUILD_NON_INTERACTIVE=1 bash "$GUARD" 2>/dev/null || true)
if printf '%s' "$stdout27" | grep -q '"decision"'; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: headless_suppresses_intent_escape: CODEGEN_BUILD_NON_INTERACTIVE=1 → block\n'
    pass=$((pass + 1))
else
    printf 'FAIL: headless_suppresses_intent_escape: expected block, got allow\n  stdout: %s\n' "$stdout27"
    fail=$((fail + 1))
fi
rm -rf "$tmp27"
rm -f "/tmp/claude-cycle-guard-test-sess-headless-scg.count"

# ── Test 28: interactive still allows intent question (regression guard) ──────
rm -f "/tmp/claude-cycle-guard-test-sess-28.count"
tmp28=$(mktemp -d)
printf '%s\n' "$AGENT_ENTRY_DEVELOPER" >"$tmp28/transcript.jsonl"
INPUT28=$(make_input "$tmp28/transcript.jsonl" "$tmp28" "false" "Should I continue?" "test-sess-28")
stdout28=$(printf '%s' "$INPUT28" | env -u CODEGEN_BUILD_NON_INTERACTIVE bash "$GUARD" 2>/dev/null || true)
if ! printf '%s' "$stdout28" | grep -q '"decision"'; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: interactive_intent_still_allows: no CODEGEN_BUILD_NON_INTERACTIVE → allow\n'
    pass=$((pass + 1))
else
    printf 'FAIL: interactive_intent_still_allows: expected allow, got block\n  stdout: %s\n' "$stdout28"
    fail=$((fail + 1))
fi
rm -rf "$tmp28"
rm -f "/tmp/claude-cycle-guard-test-sess-28.count"

# ── Test 29: skip when CLAUDE_ROLE=shape (investigative mode) ────────────────
rm -f "/tmp/claude-cycle-guard-test-sess-29.count"
tmp29=$(mktemp -d)
printf '%s\n' "$AGENT_ENTRY_DEVELOPER" >"$tmp29/transcript.jsonl"
INPUT29=$(make_input "$tmp29/transcript.jsonl" "$tmp29" "false" "Done." "test-sess-29")
stdout29=$(printf '%s' "$INPUT29" | CLAUDE_ROLE=shape bash "$GUARD" 2>/dev/null || true)
if ! printf '%s' "$stdout29" | grep -q '"decision"[[:space:]]*:[[:space:]]*"block"'; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: investigative_skip: CLAUDE_ROLE=shape → allow (would block in build mode)\n'
    pass=$((pass + 1))
else
    printf 'FAIL: investigative_skip: expected allow for CLAUDE_ROLE=shape, got block\n  stdout: %s\n' "$stdout29"
    fail=$((fail + 1))
fi
rm -rf "$tmp29"
rm -f "/tmp/claude-cycle-guard-test-sess-29.count"

# ── Test 30: build mode (role unset) still blocks — behavior unchanged ────────
rm -f "/tmp/claude-cycle-guard-test-sess-30.count"
tmp30=$(mktemp -d)
printf '%s\n' "$AGENT_ENTRY_DEVELOPER" >"$tmp30/transcript.jsonl"
INPUT30=$(make_input "$tmp30/transcript.jsonl" "$tmp30" "false" "Done." "test-sess-30")
stdout30=$(printf '%s' "$INPUT30" | env -u CLAUDE_ROLE -u PI_ROLE bash "$GUARD" 2>/dev/null || true)
if printf '%s' "$stdout30" | grep -q '"decision"[[:space:]]*:[[:space:]]*"block"'; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: build_mode_blocks: role unset → block (gate unchanged)\n'
    pass=$((pass + 1))
else
    printf 'FAIL: build_mode_blocks: expected block when role unset (build mode)\n  stdout: %s\n' "$stdout30"
    fail=$((fail + 1))
fi
rm -rf "$tmp30"
rm -f "/tmp/claude-cycle-guard-test-sess-30.count"

# ── Test 31: CLAUDE_ROLE=build still blocks (explicit build role) ────────────
rm -f "/tmp/claude-cycle-guard-test-sess-31.count"
tmp31=$(mktemp -d)
printf '%s\n' "$AGENT_ENTRY_DEVELOPER" >"$tmp31/transcript.jsonl"
INPUT31=$(make_input "$tmp31/transcript.jsonl" "$tmp31" "false" "Done." "test-sess-31")
stdout31=$(printf '%s' "$INPUT31" | CLAUDE_ROLE=build bash "$GUARD" 2>/dev/null || true)
if printf '%s' "$stdout31" | grep -q '"decision"[[:space:]]*:[[:space:]]*"block"'; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: build_role_blocks: CLAUDE_ROLE=build → block (explicit build role enforces)\n'
    pass=$((pass + 1))
else
    printf 'FAIL: build_role_blocks: expected block for CLAUDE_ROLE=build\n  stdout: %s\n' "$stdout31"
    fail=$((fail + 1))
fi
rm -rf "$tmp31"
rm -f "/tmp/claude-cycle-guard-test-sess-31.count"

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
