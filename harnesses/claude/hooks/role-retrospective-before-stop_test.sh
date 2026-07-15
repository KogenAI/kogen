#!/usr/bin/env bash
# role-retrospective-before-stop_test.sh — unit tests for role-retrospective-before-stop.sh
#
# Tests:
#   1: planner-phoenix, ev:role + ev:learned present → allow
#   2: planner-phoenix, ev:role present, no ev:learned/no_learning → block; names codegen-log append --learned
#   3: developer-phoenix-backend, no ev:role at all → block; names codegen-log section
#   4: reviewer-phoenix, ev:learned present (any text — substance is a writer-side concern) → allow
#   5: reviewer-static, ev:no_learning present (no ev:learned) → allow (legal empty-turn exit)
#   6: developer-static, ev:learned present → allow
#   7: developer-static, ev:learned present → allow
#   8: AGENT_TYPE=context-curator → allow (exempt)
#   9: AGENT_TYPE=committer → allow (exempt)
#  10: AGENT_TYPE="" → allow (fail-open)
#  11: STOP_HOOK_ACTIVE=true → allow (recursion guard)
#  12: no cycle log resolvable → allow (fail-open)
#  13: counter already at 3 → allow, counter removed, stderr contains "proceeding without it"
#  14: counter increments 0→1 on first block, 1→2 on second
#  15: ev:role body whitespace-only → block (work missing)
#  16: ev:learned belongs to a DIFFERENT role → block (selector is role-scoped)
#  17: block reason never publishes a passing criterion (no "40 char"/"forty" wording)

set -u
# Unset CODEGEN_LOG_PATH to isolate test fixtures from the active loop log
unset CODEGEN_LOG_PATH


SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/role-retrospective-before-stop.sh"

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

# make_stop_input <cwd> <agent_type> <stop_hook_active> <transcript_path> <session_id>
make_stop_input() {
    local cwd="$1"
    local agent_type="$2"
    local stop_active="${3:-false}"
    local transcript_path="${4:-}"
    local session_id="${5:-testsession}"
    jq -n \
        --arg cwd "$cwd" \
        --arg agent_type "$agent_type" \
        --argjson stop_active "$stop_active" \
        --arg transcript_path "$transcript_path" \
        --arg session_id "$session_id" \
        '{"hook_event_name":"Stop","cwd":$cwd,"session_id":$session_id,"agent_type":$agent_type,"stop_hook_active":$stop_active,"transcript_path":$transcript_path}'
}

# make_transcript_with_log_write <transcript_path> <log_path>
make_transcript_with_log_write() {
    local transcript_path="$1"
    local log_path="$2"
    printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"%s"}}]}}\n' \
        "$log_path" >"$transcript_path"
}

# append_role_event <log_path> <role> <body>
append_role_event() {
    local log_path="$1"
    local role="$2"
    local body="$3"
    jq -c -n --arg role "$role" --arg body "$body" '{ev:"role", role:$role, body:$body}' >>"$log_path"
}

# append_learned_event <log_path> <role> <text>
append_learned_event() {
    local log_path="$1"
    local role="$2"
    local text="$3"
    jq -c -n --arg role "$role" --arg text "$text" '{ev:"learned", role:$role, text:$text}' >>"$log_path"
}

VALID_LEARNING="This is a genuinely useful retrospective sentence describing what was learned."

# Session ids are suffixed with $$ (this process's PID) so concurrent
# invocations of this SAME test file (run-tests.sh's xargs -P parallelism can
# invoke identical *_test.sh content more than once in-flight, and `make test`
# itself runs several test suites concurrently) never share a
# /tmp/claude-retro-<sid>.count counter file. Without the suffix, two parallel
# copies of this file race on the same fixed sess1..sess16 ids: one instance's
# cleanup trap deletes a counter the other instance is mid-check on, and a
# block-expecting test silently observes an "allow" (empty output) instead —
# exactly the flake reproduced by running 8 copies of this file simultaneously.
SUFFIX="$$"
cleanup_counters() {
    local i
    for i in $(seq 1 17); do
        rm -f "/tmp/claude-retro-sess${i}-${SUFFIX}.count"
    done
    rm -f "/tmp/claude-retro-sess13-exhausted-${SUFFIX}.count" \
        "/tmp/claude-retro-sess14-increment-${SUFFIX}.count"
}
cleanup_counters
trap cleanup_counters EXIT

# ── Test 1: valid work + valid learning → allow ──────────────────────────────
T1_dir=$(mktemp -d)
mkdir -p "$T1_dir/codegen/logging"
T1_log="$T1_dir/codegen/logging/20260714_test_cycle.jsonl"
T1_transcript="$T1_dir/transcript.jsonl"
append_role_event "$T1_log" "planner-phoenix" "Did the planning work."
append_learned_event "$T1_log" "planner-phoenix" "$VALID_LEARNING"
make_transcript_with_log_write "$T1_transcript" "$T1_log"
out=$(make_stop_input "$T1_dir" "planner-phoenix" false "$T1_transcript" "sess1-${SUFFIX}" | bash "$HOOK" 2>/dev/null || true)
assert_not_contains "planner-phoenix, work+learning present → allow" '"decision"' "$out"
rm -rf "$T1_dir"

# ── Test 2: work present, no learning → block, names append --learned ───────
T2_dir=$(mktemp -d)
mkdir -p "$T2_dir/codegen/logging"
T2_log="$T2_dir/codegen/logging/20260714_test_cycle.jsonl"
T2_transcript="$T2_dir/transcript.jsonl"
append_role_event "$T2_log" "planner-phoenix" "Did the planning work."
make_transcript_with_log_write "$T2_transcript" "$T2_log"
out=$(make_stop_input "$T2_dir" "planner-phoenix" false "$T2_transcript" "sess2-${SUFFIX}" | bash "$HOOK" 2>/dev/null || true)
assert_contains "planner-phoenix, no learning → block" '"decision"' "$out"
assert_contains "block reason names codegen-log append --no-learning" 'codegen-log append planner-phoenix --no-learning' "$out"
rm -rf "$T2_dir"

# ── Test 3: no ev:role at all → block, names codegen-log section ────────────
T3_dir=$(mktemp -d)
mkdir -p "$T3_dir/codegen/logging"
T3_log="$T3_dir/codegen/logging/20260714_test_cycle.jsonl"
T3_transcript="$T3_dir/transcript.jsonl"
: >"$T3_log"
make_transcript_with_log_write "$T3_transcript" "$T3_log"
out=$(make_stop_input "$T3_dir" "developer-phoenix-backend" false "$T3_transcript" "sess3-${SUFFIX}" | bash "$HOOK" 2>/dev/null || true)
assert_contains "developer-phoenix-backend, no ev:role → block" '"decision"' "$out"
assert_contains "block reason names codegen-log section" 'codegen-log section developer-phoenix-backend' "$out"
rm -rf "$T3_dir"

# ── Test 4: ev:learned present (any text — substance checked at writer) → allow
T4_dir=$(mktemp -d)
mkdir -p "$T4_dir/codegen/logging"
T4_log="$T4_dir/codegen/logging/20260714_test_cycle.jsonl"
T4_transcript="$T4_dir/transcript.jsonl"
append_role_event "$T4_log" "reviewer-phoenix" "Reviewed the code."
append_learned_event "$T4_log" "reviewer-phoenix" "$VALID_LEARNING"
make_transcript_with_log_write "$T4_transcript" "$T4_log"
out=$(make_stop_input "$T4_dir" "reviewer-phoenix" false "$T4_transcript" "sess4-${SUFFIX}" | bash "$HOOK" 2>/dev/null || true)
assert_not_contains "reviewer-phoenix, ev:learned present → allow" '"decision"' "$out"
rm -rf "$T4_dir"

# ── Test 5: ev:no_learning present (no ev:learned) → allow (legal empty-turn
# exit; codegen-log itself is the substance gate, not this hook) ────────────
T5_dir=$(mktemp -d)
mkdir -p "$T5_dir/codegen/logging"
T5_log="$T5_dir/codegen/logging/20260714_test_cycle.jsonl"
T5_transcript="$T5_dir/transcript.jsonl"
append_role_event "$T5_log" "reviewer-static" "Reviewed the code."
jq -c -n --arg role "reviewer-static" --arg text "refused: handoff named no files, reviewed zero code" \
    '{ev:"no_learning", role:$role, text:$text}' >>"$T5_log"
make_transcript_with_log_write "$T5_transcript" "$T5_log"
out=$(make_stop_input "$T5_dir" "reviewer-static" false "$T5_transcript" "sess5-${SUFFIX}" | bash "$HOOK" 2>/dev/null || true)
assert_not_contains "reviewer-static, ev:no_learning present → allow" '"decision"' "$out"
rm -rf "$T5_dir"

# ── Test 6: developer-static, ev:learned present → allow ────────────────────
T6_dir=$(mktemp -d)
mkdir -p "$T6_dir/codegen/logging"
T6_log="$T6_dir/codegen/logging/20260714_test_cycle.jsonl"
T6_transcript="$T6_dir/transcript.jsonl"
append_role_event "$T6_log" "developer-static" "Did dev work."
append_learned_event "$T6_log" "developer-static" "$VALID_LEARNING"
make_transcript_with_log_write "$T6_transcript" "$T6_log"
out=$(make_stop_input "$T6_dir" "developer-static" false "$T6_transcript" "sess6-${SUFFIX}" | bash "$HOOK" 2>/dev/null || true)
assert_not_contains "developer-static, ev:learned present → allow" '"decision"' "$out"
rm -rf "$T6_dir"

# ── Test 7: developer-static, ev:learned present with real content → allow ──
T7_dir=$(mktemp -d)
mkdir -p "$T7_dir/codegen/logging"
T7_log="$T7_dir/codegen/logging/20260714_test_cycle.jsonl"
T7_transcript="$T7_dir/transcript.jsonl"
append_role_event "$T7_log" "developer-static" "Did dev work."
append_learned_event "$T7_log" "developer-static" "$VALID_LEARNING"
make_transcript_with_log_write "$T7_transcript" "$T7_log"
out=$(make_stop_input "$T7_dir" "developer-static" false "$T7_transcript" "sess7-${SUFFIX}" | bash "$HOOK" 2>/dev/null || true)
assert_not_contains "developer-static, work+learning present → allow" '"decision"' "$out"
rm -rf "$T7_dir"

# ── Test 8: AGENT_TYPE=context-curator → allow (exempt) ─────────────────────
T8_dir=$(mktemp -d)
mkdir -p "$T8_dir/codegen/logging"
T8_log="$T8_dir/codegen/logging/20260714_test_cycle.jsonl"
T8_transcript="$T8_dir/transcript.jsonl"
: >"$T8_log"
make_transcript_with_log_write "$T8_transcript" "$T8_log"
out=$(make_stop_input "$T8_dir" "context-curator" false "$T8_transcript" "sess8-${SUFFIX}" | bash "$HOOK" 2>/dev/null || true)
assert_not_contains "context-curator → allow (exempt)" '"decision"' "$out"
rm -rf "$T8_dir"

# ── Test 9: AGENT_TYPE=committer → allow (exempt) ────────────────────────────
T9_dir=$(mktemp -d)
mkdir -p "$T9_dir/codegen/logging"
T9_log="$T9_dir/codegen/logging/20260714_test_cycle.jsonl"
T9_transcript="$T9_dir/transcript.jsonl"
: >"$T9_log"
make_transcript_with_log_write "$T9_transcript" "$T9_log"
out=$(make_stop_input "$T9_dir" "committer" false "$T9_transcript" "sess9-${SUFFIX}" | bash "$HOOK" 2>/dev/null || true)
assert_not_contains "committer → allow (exempt)" '"decision"' "$out"
rm -rf "$T9_dir"

# ── Test 10: AGENT_TYPE="" → allow (fail-open) ───────────────────────────────
T10_dir=$(mktemp -d)
out=$(make_stop_input "$T10_dir" "" false "" "sess10-${SUFFIX}" | bash "$HOOK" 2>/dev/null || true)
assert_not_contains "AGENT_TYPE empty → allow (fail-open)" '"decision"' "$out"
rm -rf "$T10_dir"

# ── Test 11: STOP_HOOK_ACTIVE=true → allow (recursion guard) ────────────────
T11_dir=$(mktemp -d)
mkdir -p "$T11_dir/codegen/logging"
T11_log="$T11_dir/codegen/logging/20260714_test_cycle.jsonl"
T11_transcript="$T11_dir/transcript.jsonl"
: >"$T11_log"
make_transcript_with_log_write "$T11_transcript" "$T11_log"
out=$(make_stop_input "$T11_dir" "planner-phoenix" true "$T11_transcript" "sess11-${SUFFIX}" | bash "$HOOK" 2>/dev/null || true)
assert_not_contains "STOP_HOOK_ACTIVE=true → allow (recursion guard)" '"decision"' "$out"
rm -rf "$T11_dir"

# ── Test 12: no cycle log resolvable → allow (fail-open) ────────────────────
T12_dir=$(mktemp -d)
out=$(make_stop_input "$T12_dir" "planner-phoenix" false "" "sess12-${SUFFIX}" | bash "$HOOK" 2>/dev/null || true)
assert_not_contains "no cycle log resolvable → allow (fail-open)" '"decision"' "$out"
rm -rf "$T12_dir"

# ── Test 13: counter already at 3 → allow, counter removed, stderr message ──
T13_dir=$(mktemp -d)
mkdir -p "$T13_dir/codegen/logging"
T13_log="$T13_dir/codegen/logging/20260714_test_cycle.jsonl"
T13_transcript="$T13_dir/transcript.jsonl"
: >"$T13_log"
make_transcript_with_log_write "$T13_transcript" "$T13_log"
T13_session="sess13-exhausted-${SUFFIX}"
T13_counter="/tmp/claude-retro-${T13_session}.count"
printf '3' >"$T13_counter"
T13_stdout_file=$(mktemp)
T13_stderr_file=$(mktemp)
make_stop_input "$T13_dir" "developer-phoenix-backend" false "$T13_transcript" "$T13_session" |
    bash "$HOOK" >"$T13_stdout_file" 2>"$T13_stderr_file" || true
out=$(cat "$T13_stdout_file")
stderr_out=$(cat "$T13_stderr_file")
assert_not_contains "counter exhausted (3) → allow" '"decision"' "$out"
assert_contains "stderr mentions proceeding without it" 'proceeding without it' "$stderr_out"
rm -f "$T13_stdout_file" "$T13_stderr_file"
if [ -f "$T13_counter" ]; then
    printf 'FAIL: counter file should be removed after exhaustion: %s\n' "$T13_counter"
    fail=$((fail + 1))
else
    pass=$((pass + 1))
fi
rm -f "$T13_counter"
rm -rf "$T13_dir"

# ── Test 14: counter increments 0→1 on first block, 1→2 on second ───────────
T14_dir=$(mktemp -d)
mkdir -p "$T14_dir/codegen/logging"
T14_log="$T14_dir/codegen/logging/20260714_test_cycle.jsonl"
T14_transcript="$T14_dir/transcript.jsonl"
: >"$T14_log"
make_transcript_with_log_write "$T14_transcript" "$T14_log"
T14_session="sess14-increment-${SUFFIX}"
T14_counter="/tmp/claude-retro-${T14_session}.count"
rm -f "$T14_counter"
make_stop_input "$T14_dir" "developer-phoenix-backend" false "$T14_transcript" "$T14_session" | bash "$HOOK" >/dev/null 2>&1 || true
count_after_1=$(cat "$T14_counter" 2>/dev/null || echo "MISSING")
make_stop_input "$T14_dir" "developer-phoenix-backend" false "$T14_transcript" "$T14_session" | bash "$HOOK" >/dev/null 2>&1 || true
count_after_2=$(cat "$T14_counter" 2>/dev/null || echo "MISSING")
if [ "$count_after_1" = "1" ] && [ "$count_after_2" = "2" ]; then
    pass=$((pass + 1))
    [ -n "${VERBOSE:-}" ] && printf 'PASS: counter increments 0→1→2\n'
else
    printf 'FAIL: counter increments 0→1→2\n  got: %s then %s\n' "$count_after_1" "$count_after_2"
    fail=$((fail + 1))
fi
rm -f "$T14_counter"
rm -rf "$T14_dir"

# ── Test 15: ev:role body whitespace-only → block (work missing) ────────────
T15_dir=$(mktemp -d)
mkdir -p "$T15_dir/codegen/logging"
T15_log="$T15_dir/codegen/logging/20260714_test_cycle.jsonl"
T15_transcript="$T15_dir/transcript.jsonl"
append_role_event "$T15_log" "planner-phoenix" "   "
append_learned_event "$T15_log" "planner-phoenix" "$VALID_LEARNING"
make_transcript_with_log_write "$T15_transcript" "$T15_log"
out=$(make_stop_input "$T15_dir" "planner-phoenix" false "$T15_transcript" "sess15-${SUFFIX}" | bash "$HOOK" 2>/dev/null || true)
assert_contains "planner-phoenix, whitespace-only body → block (work missing)" '"decision"' "$out"
rm -rf "$T15_dir"

# ── Test 16: ev:learned belongs to a DIFFERENT role → block ─────────────────
T16_dir=$(mktemp -d)
mkdir -p "$T16_dir/codegen/logging"
T16_log="$T16_dir/codegen/logging/20260714_test_cycle.jsonl"
T16_transcript="$T16_dir/transcript.jsonl"
append_role_event "$T16_log" "reviewer-phoenix" "Reviewed the code."
append_learned_event "$T16_log" "developer-phoenix-backend" "$VALID_LEARNING"
make_transcript_with_log_write "$T16_transcript" "$T16_log"
out=$(make_stop_input "$T16_dir" "reviewer-phoenix" false "$T16_transcript" "sess16-${SUFFIX}" | bash "$HOOK" 2>/dev/null || true)
assert_contains "reviewer-phoenix, learned belongs to different role → block" '"decision"' "$out"
rm -rf "$T16_dir"

# ── Test 17: block reason never publishes a passing criterion ───────────────
T17_dir=$(mktemp -d)
mkdir -p "$T17_dir/codegen/logging"
T17_log="$T17_dir/codegen/logging/20260714_test_cycle.jsonl"
T17_transcript="$T17_dir/transcript.jsonl"
append_role_event "$T17_log" "planner-phoenix" "Did the planning work."
make_transcript_with_log_write "$T17_transcript" "$T17_log"
out=$(make_stop_input "$T17_dir" "planner-phoenix" false "$T17_transcript" "sess17-${SUFFIX}" | bash "$HOOK" 2>/dev/null || true)
assert_contains "planner-phoenix, no learning → block" '"decision"' "$out"
assert_not_contains "block reason never states a char-count criterion" '40 char' "$out"
assert_not_contains "block reason never states 'forty'" 'forty' "$out"
assert_contains "block reason names the --no-learning escape hatch" 'no-learning' "$out"
rm -rf "$T17_dir"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
