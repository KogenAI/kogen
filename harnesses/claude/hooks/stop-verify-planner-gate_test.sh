#!/usr/bin/env bash
# stop-verify-planner-gate_test.sh — unit tests for stop-verify-planner-gate.sh
#
# Tests:
#   1: planner-phoenix Stop, no TRANSCRIPT_PATH → exit 0 (skip)
#   2: planner-phoenix Stop, log carries a plan_gate event (command=make ci) → exit 0 (allow)
#   3: planner-phoenix Stop, plan_gate event with placeholder command "TBD" → exit 2 (block)
#   4: planner-phoenix Stop, log carries NO plan_gate event → exit 2 (block)
#   5: developer-phoenix-backend Stop → exit 0 (skip — non-planner)
#   6: planner-phoenix Stop with STOP_HOOK_ACTIVE=true → exit 0 (recursion guard)
#   7: planner-phoenix Stop, plan_gate event with placeholder command "pending" → exit 2 (block)
#   8: planner-phoenix Stop, log carries stale **Gate**: prose but NO plan_gate
#      event → exit 2 (block) — proves the prose scanner is truly gone
#   9: planner-phoenix Stop, plan_gate event with long mode/timeout → exit 0 (allow)
#  10: planner-phoenix Stop, plan_gate present but NO plan event → exit 2 (block)
#  11: planner-phoenix Stop, plan_gate + plan events both present → exit 0 (allow)
#  12: planner-phoenix Stop, plan event blank text → exit 2 (block, same as absent)

set -u

# Neutralize an ambient CODEGEN_LOG_PATH pin from the launching (this very)
# dev session — session_log_from_transcript() binds to it FIRST (see
# session-log.md § Resolution precedence), ahead of every fixture built
# below. Left set, it would silently redirect every case here onto the live
# session's own cycle log instead of the per-test tmp fixture.
unset CODEGEN_LOG_PATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/stop-verify-planner-gate.sh"

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

# make_step_log_with_plan_gate <log_path> <command> [<mode>] [<timeout>]
# Writes a JSONL cycle log with a single {"ev":"plan_gate",...} event
# authored by planner-phoenix — the structured event stop-verify-planner-gate
# actually reads (via gate_select_read_planner_gate), matching what
# `codegen-log append <role> --plan-gate @-` writes on disk.
make_step_log_with_plan_gate() {
    local log_path="$1"
    local command="$2"
    local mode="${3:-short}"
    local timeout="${4:-900}"
    jq -c -n --arg role "planner-phoenix" --arg command "$command" --arg mode "$mode" --argjson timeout "$timeout" \
        '{ev: "plan_gate", role: $role, command: $command, mode: $mode, timeout: $timeout}' >"$log_path"
}

# make_step_log_with_plan_gate_and_plan <log_path> <command> [<mode>] [<timeout>] [<plan_text>]
# Writes a JSONL cycle log with BOTH a {"ev":"plan_gate",...} event AND a
# {"ev":"plan",...} event, authored by planner-phoenix — the two typed
# markers stop-verify-planner-gate now requires both of before allowing Stop.
make_step_log_with_plan_gate_and_plan() {
    local log_path="$1"
    local command="$2"
    local mode="${3:-short}"
    local timeout="${4:-900}"
    local plan_text="${5:-## Plan

Do the thing.}"
    jq -c -n --arg role "planner-phoenix" --arg command "$command" --arg mode "$mode" --argjson timeout "$timeout" \
        '{ev: "plan_gate", role: $role, command: $command, mode: $mode, timeout: $timeout}' >"$log_path"
    jq -c -n --arg role "planner-phoenix" --arg plan "$plan_text" \
        '{ev: "plan", role: $role, plan: $plan}' >>"$log_path"
}

# make_step_log_no_gate <log_path>
# Writes a JSONL cycle log with a planner-phoenix role event body but NO
# plan_gate event.
make_step_log_no_gate() {
    local log_path="$1"
    local body
    body=$(printf '# Step 1 — test\n\n## Plan\n\nSome plan content without a gate line.')
    jq -c -n --arg role "planner-phoenix" --arg body "$body" '{ev: "role", role: $role, body: $body}' >"$log_path"
}

# make_step_log_stale_prose_no_event <log_path>
# Writes a JSONL cycle log whose role body contains OLD-style "**Gate**:"
# prose but carries NO plan_gate event — proves the prose scanner is gone:
# this body would have satisfied the old awk parser, and must now block
# exactly like make_step_log_no_gate.
make_step_log_stale_prose_no_event() {
    local log_path="$1"
    local body
    body=$(printf '# Step 1 — test\n\n## Plan\n\n**Gate**: `make ci`\n\nstuff')
    jq -c -n --arg role "planner-phoenix" --arg body "$body" '{ev: "role", role: $role, body: $body}' >"$log_path"
}

# ── Test 1: no TRANSCRIPT_PATH → no block ────────────────────────────────────
T1_dir=$(mktemp -d)
out=$(make_stop_input "$T1_dir" "planner-phoenix" false "" | bash "$HOOK" 2>/dev/null || true)
assert_not_contains "planner Stop, no TRANSCRIPT_PATH → no block" '"decision"' "$out"
rm -rf "$T1_dir"

# ── Test 2: plan_gate event (command=make ci) + plan event → allow ──────────
T2_dir=$(mktemp -d)
mkdir -p "$T2_dir/codegen/logging"
T2_log="$T2_dir/codegen/logging/20260518_test_cycle.jsonl"
T2_transcript="$T2_dir/transcript.jsonl"
make_step_log_with_plan_gate_and_plan "$T2_log" "make ci"
make_transcript_with_log_write "$T2_transcript" "$T2_log"
out=$(make_stop_input "$T2_dir" "planner-phoenix" false "$T2_transcript" | bash "$HOOK" 2>/dev/null || true)
assert_not_contains "planner Stop, plan_gate command=make ci → allow" '"decision"' "$out"
rm -rf "$T2_dir"

# ── Test 3: plan_gate event with placeholder command "TBD" → block ──────────
T3_dir=$(mktemp -d)
mkdir -p "$T3_dir/codegen/logging"
T3_log="$T3_dir/codegen/logging/20260518_test_cycle.jsonl"
T3_transcript="$T3_dir/transcript.jsonl"
make_step_log_with_plan_gate "$T3_log" "TBD"
make_transcript_with_log_write "$T3_transcript" "$T3_log"
out=$(make_stop_input "$T3_dir" "planner-phoenix" false "$T3_transcript" | bash "$HOOK" 2>/dev/null || true)
assert_contains "planner Stop, plan_gate command=TBD → block" '"decision"' "$out"
assert_contains "block reason cites step log" 'stop-verify-planner-gate' "$out"
rm -rf "$T3_dir"

# ── Test 4: log carries NO plan_gate event → block ───────────────────────────
T4_dir=$(mktemp -d)
mkdir -p "$T4_dir/codegen/logging"
T4_log="$T4_dir/codegen/logging/20260518_test_cycle.jsonl"
T4_transcript="$T4_dir/transcript.jsonl"
make_step_log_no_gate "$T4_log"
make_transcript_with_log_write "$T4_transcript" "$T4_log"
out=$(make_stop_input "$T4_dir" "planner-phoenix" false "$T4_transcript" | bash "$HOOK" 2>/dev/null || true)
assert_contains "planner Stop, no plan_gate event → block" '"decision"' "$out"
rm -rf "$T4_dir"

# ── Test 5: developer-phoenix-backend Stop → no block ────────────────────────
T5_dir=$(mktemp -d)
mkdir -p "$T5_dir/codegen/logging"
T5_log="$T5_dir/codegen/logging/20260518_test_cycle.jsonl"
T5_transcript="$T5_dir/transcript.jsonl"
make_step_log_no_gate "$T5_log"
make_transcript_with_log_write "$T5_transcript" "$T5_log"
out=$(make_stop_input "$T5_dir" "developer-phoenix-backend" false "$T5_transcript" | bash "$HOOK" 2>/dev/null || true)
assert_not_contains "developer-phoenix-backend Stop → no block (non-planner)" '"decision"' "$out"
rm -rf "$T5_dir"

# ── Test 6: planner Stop with STOP_HOOK_ACTIVE=true → no block ───────────────
T6_dir=$(mktemp -d)
mkdir -p "$T6_dir/codegen/logging"
T6_log="$T6_dir/codegen/logging/20260518_test_cycle.jsonl"
T6_transcript="$T6_dir/transcript.jsonl"
make_step_log_no_gate "$T6_log"
make_transcript_with_log_write "$T6_transcript" "$T6_log"
out=$(make_stop_input "$T6_dir" "planner-phoenix" true "$T6_transcript" | bash "$HOOK" 2>/dev/null || true)
assert_not_contains "planner Stop STOP_HOOK_ACTIVE=true → no block (recursion guard)" '"decision"' "$out"
rm -rf "$T6_dir"

# ── Test 7: plan_gate event with placeholder command "pending" → block ──────
T7_dir=$(mktemp -d)
mkdir -p "$T7_dir/codegen/logging"
T7_log="$T7_dir/codegen/logging/20260518_test_cycle.jsonl"
T7_transcript="$T7_dir/transcript.jsonl"
make_step_log_with_plan_gate "$T7_log" "pending"
make_transcript_with_log_write "$T7_transcript" "$T7_log"
out=$(make_stop_input "$T7_dir" "planner-phoenix" false "$T7_transcript" | bash "$HOOK" 2>/dev/null || true)
assert_contains "planner Stop, plan_gate command=pending → block" '"decision"' "$out"
rm -rf "$T7_dir"

# ── Test 8: stale **Gate**: prose with NO plan_gate event → block ────────────
# Proves the prose scanner is gone: a body carrying old-style "**Gate**:"
# markdown (which the old awk parser would have accepted) must now block
# exactly like a log with no gate signal at all.
T8_dir=$(mktemp -d)
mkdir -p "$T8_dir/codegen/logging"
T8_log="$T8_dir/codegen/logging/20260518_test_cycle.jsonl"
T8_transcript="$T8_dir/transcript.jsonl"
make_step_log_stale_prose_no_event "$T8_log"
make_transcript_with_log_write "$T8_transcript" "$T8_log"
out=$(make_stop_input "$T8_dir" "planner-phoenix" false "$T8_transcript" | bash "$HOOK" 2>/dev/null || true)
assert_contains "planner Stop, stale **Gate**: prose (no event) → block" '"decision"' "$out"
rm -rf "$T8_dir"

# ── Test 9: plan_gate event with long mode/timeout + plan event → allow ─────
T9_dir=$(mktemp -d)
mkdir -p "$T9_dir/codegen/logging"
T9_log="$T9_dir/codegen/logging/20260518_test_cycle.jsonl"
T9_transcript="$T9_dir/transcript.jsonl"
make_step_log_with_plan_gate_and_plan "$T9_log" "make ci && make llm" "long" "1800"
make_transcript_with_log_write "$T9_transcript" "$T9_log"
out=$(make_stop_input "$T9_dir" "planner-phoenix" false "$T9_transcript" | bash "$HOOK" 2>/dev/null || true)
assert_not_contains "planner Stop, plan_gate long mode/timeout → allow" '"decision"' "$out"
rm -rf "$T9_dir"

# ── Test 10: plan_gate present, NO plan event → block ────────────────────────
T10_dir=$(mktemp -d)
mkdir -p "$T10_dir/codegen/logging"
T10_log="$T10_dir/codegen/logging/20260518_test_cycle.jsonl"
T10_transcript="$T10_dir/transcript.jsonl"
make_step_log_with_plan_gate "$T10_log" "make ci"
make_transcript_with_log_write "$T10_transcript" "$T10_log"
out=$(make_stop_input "$T10_dir" "planner-phoenix" false "$T10_transcript" | bash "$HOOK" 2>/dev/null || true)
assert_contains "planner Stop, plan_gate present but no plan event → block" '"decision"' "$out"
assert_contains "block reason names the missing plan event" "codegen-log append" "$out"
rm -rf "$T10_dir"

# ── Test 11: plan_gate + plan events both present → allow ────────────────────
T11_dir=$(mktemp -d)
mkdir -p "$T11_dir/codegen/logging"
T11_log="$T11_dir/codegen/logging/20260518_test_cycle.jsonl"
T11_transcript="$T11_dir/transcript.jsonl"
make_step_log_with_plan_gate_and_plan "$T11_log" "make ci" "short" "900" "## Plan

**Approach**: do the thing."
make_transcript_with_log_write "$T11_transcript" "$T11_log"
out=$(make_stop_input "$T11_dir" "planner-phoenix" false "$T11_transcript" | bash "$HOOK" 2>/dev/null || true)
assert_not_contains "planner Stop, plan_gate + plan both present → allow" '"decision"' "$out"
rm -rf "$T11_dir"

# ── Test 12: plan event blank text → block (same as absent) ──────────────────
T12_dir=$(mktemp -d)
mkdir -p "$T12_dir/codegen/logging"
T12_log="$T12_dir/codegen/logging/20260518_test_cycle.jsonl"
T12_transcript="$T12_dir/transcript.jsonl"
make_step_log_with_plan_gate "$T12_log" "make ci"
jq -c -n '{ev: "plan", role: "planner-phoenix", plan: "   "}' >>"$T12_log"
make_transcript_with_log_write "$T12_transcript" "$T12_log"
out=$(make_stop_input "$T12_dir" "planner-phoenix" false "$T12_transcript" | bash "$HOOK" 2>/dev/null || true)
assert_contains "planner Stop, blank plan event text → block" '"decision"' "$out"
rm -rf "$T12_dir"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
