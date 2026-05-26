#!/usr/bin/env bash
# stop-verify-planner-gate_test.sh — unit tests for stop-verify-planner-gate.sh
#
# Tests:
#   1: planner-phoenix Stop, no TRANSCRIPT_PATH → exit 0 (skip)
#   2: planner-phoenix Stop, transcript references log with **Gate**: make ci → exit 0 (allow)
#   3: planner-phoenix Stop, transcript references log with **Gate**: TBD → exit 2 (block)
#   4: planner-phoenix Stop, transcript references log with NO **Gate**: line → exit 2 (block)
#   5: developer-phoenix-backend Stop → exit 0 (skip — non-planner)
#   6: planner-phoenix Stop with STOP_HOOK_ACTIVE=true → exit 0 (recursion guard)
#   7: planner-phoenix Stop, transcript references log with **Gate**: pending → exit 2 (block)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/stop-verify-planner-gate.sh"

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

# make_stop_input <cwd> <agent_type> <stop_hook_active> <transcript_path>
make_stop_input() {
    local cwd="$1"
    local agent_type="$2"
    local stop_active="${3:-false}"
    local transcript_path="${4:-}"
    jq -n \
        --arg cwd "$cwd" \
        --arg agent_type "$agent_type" \
        --argjson stop_active "$stop_active" \
        --arg transcript_path "$transcript_path" \
        '{"hook_event_name":"Stop","cwd":$cwd,"session_id":"testsession","agent_type":$agent_type,"stop_hook_active":$stop_active,"transcript_path":$transcript_path}'
}

# make_transcript_with_log_write <transcript_path> <log_path>
# Records an Edit tool_use entry writing to the log_path (simulates planner editing step log).
make_transcript_with_log_write() {
    local transcript_path="$1"
    local log_path="$2"
    printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"%s"}}]}}\n' \
        "$log_path" >"$transcript_path"
}

# make_step_log_with_gate <log_path> <gate_value>
# Writes a minimal step log with ## Plan and **Gate**: <gate_value>.
make_step_log_with_gate() {
    local log_path="$1"
    local gate_value="$2"
    printf '# Step 1 — test\n\n## Plan\n\n**Gate**: %s\n' "$gate_value" >"$log_path"
}

# make_step_log_no_gate <log_path>
# Writes a minimal step log with ## Plan but NO **Gate**: line.
make_step_log_no_gate() {
    local log_path="$1"
    printf '# Step 1 — test\n\n## Plan\n\nSome plan content without a gate line.\n' >"$log_path"
}

# ── Test 1: no TRANSCRIPT_PATH → no block ────────────────────────────────────
T1_dir=$(mktemp -d)
out=$(make_stop_input "$T1_dir" "planner-phoenix" false "" | bash "$HOOK" 2>/dev/null || true)
assert_not_contains "planner Stop, no TRANSCRIPT_PATH → no block" '"decision"' "$out"
rm -rf "$T1_dir"

# ── Test 2: transcript references log with **Gate**: make ci → allow ─────────
T2_dir=$(mktemp -d)
mkdir -p "$T2_dir/codegen/logging"
T2_log="$T2_dir/codegen/logging/20260518_step1_test.md"
T2_transcript="$T2_dir/transcript.jsonl"
make_step_log_with_gate "$T2_log" "make ci"
make_transcript_with_log_write "$T2_transcript" "$T2_log"
out=$(make_stop_input "$T2_dir" "planner-phoenix" false "$T2_transcript" | bash "$HOOK" 2>/dev/null || true)
assert_not_contains "planner Stop, **Gate**: make ci → allow" '"decision"' "$out"
rm -rf "$T2_dir"

# ── Test 3: transcript references log with **Gate**: TBD → block ─────────────
T3_dir=$(mktemp -d)
mkdir -p "$T3_dir/codegen/logging"
T3_log="$T3_dir/codegen/logging/20260518_step1_test.md"
T3_transcript="$T3_dir/transcript.jsonl"
make_step_log_with_gate "$T3_log" "TBD (planner to determine)"
make_transcript_with_log_write "$T3_transcript" "$T3_log"
out=$(make_stop_input "$T3_dir" "planner-phoenix" false "$T3_transcript" | bash "$HOOK" 2>/dev/null || true)
assert_contains "planner Stop, **Gate**: TBD → block" '"decision"' "$out"
assert_contains "block reason cites step log" 'stop-verify-planner-gate' "$out"
rm -rf "$T3_dir"

# ── Test 4: transcript references log with NO **Gate**: line → block ──────────
T4_dir=$(mktemp -d)
mkdir -p "$T4_dir/codegen/logging"
T4_log="$T4_dir/codegen/logging/20260518_step1_test.md"
T4_transcript="$T4_dir/transcript.jsonl"
make_step_log_no_gate "$T4_log"
make_transcript_with_log_write "$T4_transcript" "$T4_log"
out=$(make_stop_input "$T4_dir" "planner-phoenix" false "$T4_transcript" | bash "$HOOK" 2>/dev/null || true)
assert_contains "planner Stop, no **Gate**: line → block" '"decision"' "$out"
rm -rf "$T4_dir"

# ── Test 5: developer-phoenix-backend Stop → no block ────────────────────────
T5_dir=$(mktemp -d)
mkdir -p "$T5_dir/codegen/logging"
T5_log="$T5_dir/codegen/logging/20260518_step1_test.md"
T5_transcript="$T5_dir/transcript.jsonl"
make_step_log_no_gate "$T5_log"
make_transcript_with_log_write "$T5_transcript" "$T5_log"
out=$(make_stop_input "$T5_dir" "developer-phoenix-backend" false "$T5_transcript" | bash "$HOOK" 2>/dev/null || true)
assert_not_contains "developer-phoenix-backend Stop → no block (non-planner)" '"decision"' "$out"
rm -rf "$T5_dir"

# ── Test 6: planner Stop with STOP_HOOK_ACTIVE=true → no block ───────────────
T6_dir=$(mktemp -d)
mkdir -p "$T6_dir/codegen/logging"
T6_log="$T6_dir/codegen/logging/20260518_step1_test.md"
T6_transcript="$T6_dir/transcript.jsonl"
make_step_log_no_gate "$T6_log"
make_transcript_with_log_write "$T6_transcript" "$T6_log"
out=$(make_stop_input "$T6_dir" "planner-phoenix" true "$T6_transcript" | bash "$HOOK" 2>/dev/null || true)
assert_not_contains "planner Stop STOP_HOOK_ACTIVE=true → no block (recursion guard)" '"decision"' "$out"
rm -rf "$T6_dir"

# ── Test 7: transcript references log with **Gate**: pending → block ──────────
T7_dir=$(mktemp -d)
mkdir -p "$T7_dir/codegen/logging"
T7_log="$T7_dir/codegen/logging/20260518_step1_test.md"
T7_transcript="$T7_dir/transcript.jsonl"
make_step_log_with_gate "$T7_log" "pending"
make_transcript_with_log_write "$T7_transcript" "$T7_log"
out=$(make_stop_input "$T7_dir" "planner-phoenix" false "$T7_transcript" | bash "$HOOK" 2>/dev/null || true)
assert_contains "planner Stop, **Gate**: pending → block" '"decision"' "$out"
rm -rf "$T7_dir"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
