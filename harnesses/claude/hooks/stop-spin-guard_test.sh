#!/usr/bin/env bash
# stop-spin-guard_test.sh — unit tests for stop-spin-guard.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/stop-spin-guard.sh"

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
make_input() {
    local agent_type="$1"
    local transcript_path="$2"
    local session_id="${3:-test-spin-sess}"
    local stop_hook_active="${4:-false}"
    printf '{"hook_event_name":"SubagentStop","agent_type":"%s","session_id":"%s","transcript_path":"%s","cwd":"/tmp","stop_hook_active":%s}' \
        "$agent_type" "$session_id" "$transcript_path" "$stop_hook_active"
}

# Fixture: single developer Agent entry.
agent_entry() {
    local role="$1"
    printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Agent","input":{"subagent_type":"%s","description":"x","prompt":"x"}}]}}' "$role"
}

# Fixture: N consecutive same-role Agent entries.
n_agent_entries() {
    local role="$1"
    local n="$2"
    for _ in $(seq 1 "$n"); do
        agent_entry "$role"
        printf '\n'
    done
}

# Clean any stale spin counter files before tests.
rm -f /tmp/claude-spin-test-spin-sess.count
rm -f /tmp/claude-spin-test-spin-sess-cap.count
rm -f /tmp/claude-spin-test-spin-sess-reset.count
rm -f /tmp/claude-spin-test-spin-sess-diff.count

# --- Test 1: 1 consecutive developer → ALLOW ---
tmp1=$(mktemp -d)
agent_entry "developer-phoenix-backend" >"$tmp1/transcript.jsonl"
INPUT1=$(make_input "developer-phoenix-backend" "$tmp1/transcript.jsonl")
run_test "1_consecutive_dev: 1 spawn → allow" "allow" "$INPUT1"
rm -rf "$tmp1"

# --- Test 2: 2 consecutive same developer → ALLOW ---
tmp2=$(mktemp -d)
n_agent_entries "developer-phoenix-backend" 2 >"$tmp2/transcript.jsonl"
INPUT2=$(make_input "developer-phoenix-backend" "$tmp2/transcript.jsonl")
run_test "2_consecutive_dev: 2 spawns → allow" "allow" "$INPUT2"
rm -rf "$tmp2"

# --- Test 3: 3 consecutive same developer → BLOCK ---
tmp3=$(mktemp -d)
n_agent_entries "developer-phoenix-backend" 3 >"$tmp3/transcript.jsonl"
INPUT3=$(make_input "developer-phoenix-backend" "$tmp3/transcript.jsonl" "test-spin-sess-3a")
rm -f "/tmp/claude-spin-test-spin-sess-3a.count"
run_test "3_consecutive_dev: 3 spawns → block" "block" "$INPUT3"
rm -rf "$tmp3"

# --- Test 4: reviewer interleaved — run resets → ALLOW ---
# developer × 2 → reviewer → developer × 1: trailing run = 1 → allow.
tmp4=$(mktemp -d)
{
    n_agent_entries "developer-phoenix-backend" 2
    agent_entry "reviewer-phoenix"
    printf '\n'
    agent_entry "developer-phoenix-backend"
    printf '\n'
} >"$tmp4/transcript.jsonl"
INPUT4=$(make_input "developer-phoenix-backend" "$tmp4/transcript.jsonl")
run_test "reviewer_interleaved_resets_run: dev×2 + reviewer + dev×1 → allow" "allow" "$INPUT4"
rm -rf "$tmp4"

# --- Test 5: committer interleaved — run resets → ALLOW ---
# developer × 3 → committer → developer × 2: trailing run = 2 → allow.
tmp5=$(mktemp -d)
{
    n_agent_entries "developer-phoenix-backend" 3
    agent_entry "committer"
    printf '\n'
    n_agent_entries "developer-phoenix-backend" 2
} >"$tmp5/transcript.jsonl"
INPUT5=$(make_input "developer-phoenix-backend" "$tmp5/transcript.jsonl")
run_test "committer_interleaved_resets_run: dev×3 + committer + dev×2 → allow" "allow" "$INPUT5"
rm -rf "$tmp5"

# --- Test 6: non-developer AGENT_TYPE → SKIP (exit 0, allow) ---
tmp6=$(mktemp -d)
n_agent_entries "developer-phoenix-backend" 5 >"$tmp6/transcript.jsonl"
INPUT6=$(make_input "reviewer-phoenix" "$tmp6/transcript.jsonl")
run_test "non_developer_agent_type: reviewer-phoenix → skip (allow)" "allow" "$INPUT6"
rm -rf "$tmp6"

# --- Test 7: empty transcript → ALLOW (safe fallback) ---
tmp7=$(mktemp -d)
printf '{"type":"assistant","message":{"content":[{"type":"text","text":"Hello."}]}}\n' \
    >"$tmp7/transcript.jsonl"
INPUT7=$(make_input "developer-phoenix-backend" "$tmp7/transcript.jsonl")
run_test "empty_transcript: no Agent calls → allow" "allow" "$INPUT7"
rm -rf "$tmp7"

# --- Test 8: missing transcript path → ALLOW (safe fallback) ---
INPUT8=$(make_input "developer-phoenix-backend" "/tmp/no-such-transcript-does-not-exist.jsonl")
run_test "missing_transcript_path: nonexistent file → allow" "allow" "$INPUT8"

# --- Test 9: STOP_HOOK_ACTIVE=true → ALLOW ---
tmp9=$(mktemp -d)
n_agent_entries "developer-phoenix-backend" 3 >"$tmp9/transcript.jsonl"
INPUT9=$(make_input "developer-phoenix-backend" "$tmp9/transcript.jsonl" "test-spin-sess" "true")
run_test "stop_hook_active: stop_hook_active=true → allow" "allow" "$INPUT9"
rm -rf "$tmp9"

# --- Test 10: cap=2 release after 2 blocks → ALLOW ---
# Seed the counter file with 2 (cap) — guard must release and allow.
tmp10=$(mktemp -d)
n_agent_entries "developer-phoenix-backend" 5 >"$tmp10/transcript.jsonl"
printf '\n2' >"/tmp/claude-spin-test-spin-sess-cap.count"
INPUT10=$(make_input "developer-phoenix-backend" "$tmp10/transcript.jsonl" "test-spin-sess-cap")
run_test "cap_release: block_count=2 → cap reached → allow (cap cleared)" "allow" "$INPUT10"
rm -rf "$tmp10"
rm -f "/tmp/claude-spin-test-spin-sess-cap.count"

# --- Test 11: different developer role interleaved — run resets → ALLOW ---
# developer-phoenix-backend × 2 → developer-html × 1 → developer-phoenix-backend × 1
# trailing run of developer-phoenix-backend = 1 → allow.
tmp11=$(mktemp -d)
{
    n_agent_entries "developer-phoenix-backend" 2
    agent_entry "developer-html"
    printf '\n'
    agent_entry "developer-phoenix-backend"
    printf '\n'
} >"$tmp11/transcript.jsonl"
INPUT11=$(make_input "developer-phoenix-backend" "$tmp11/transcript.jsonl" "test-spin-sess-diff")
run_test "different_dev_role_resets_run: backend×2 + html + backend×1 → allow" "allow" "$INPUT11"
rm -rf "$tmp11"

# --- Test 12: malformed block counter → treated as 0 → applies threshold ---
tmp12=$(mktemp -d)
n_agent_entries "developer-phoenix-backend" 3 >"$tmp12/transcript.jsonl"
printf 'bad-value' >"/tmp/claude-spin-test-spin-sess-bad.count"
INPUT12=$(make_input "developer-phoenix-backend" "$tmp12/transcript.jsonl" "test-spin-sess-bad")
run_test "malformed_counter: bad counter value → treated as 0 → applies threshold" "block" "$INPUT12"
rm -rf "$tmp12"
rm -f "/tmp/claude-spin-test-spin-sess-bad.count"

# --- Test 13: context-curator interleaved — run resets → ALLOW ---
# developer × 2 → context-curator → developer × 2: trailing run = 2 → allow.
tmp13=$(mktemp -d)
{
    n_agent_entries "developer-phoenix-backend" 2
    agent_entry "context-curator"
    printf '\n'
    n_agent_entries "developer-phoenix-backend" 2
} >"$tmp13/transcript.jsonl"
INPUT13=$(make_input "developer-phoenix-backend" "$tmp13/transcript.jsonl")
run_test "curator_interleaved_resets_run: dev×2 + curator + dev×2 → allow" "allow" "$INPUT13"
rm -rf "$tmp13"

# --- Test 14: 4 consecutive same developer → BLOCK ---
# Threshold is ≥3; 4 should still block.
tmp14=$(mktemp -d)
n_agent_entries "developer-vite" 4 >"$tmp14/transcript.jsonl"
INPUT14=$(make_input "developer-vite" "$tmp14/transcript.jsonl" "test-spin-sess-vite4")
rm -f "/tmp/claude-spin-test-spin-sess-vite4.count"
run_test "4_consecutive_dev_vite: 4 spawns of developer-vite → block" "block" "$INPUT14"
rm -rf "$tmp14"
rm -f "/tmp/claude-spin-test-spin-sess-vite4.count"

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
