#!/bin/bash
# track-subagent-edits_test.sh — unit tests for track-subagent-edits.sh
#
# Tests:
#   1. Edit by a subagent appends file path to per-subagent ledger (JSONL path)
#   2. Write by a subagent appends file path to ledger
#   3. MultiEdit by a subagent appends file path to ledger
#   4. Orchestrator edit (empty agent_id) does NOT write to ledger
#   5. Non-file tool (Bash) does NOT write to ledger
#   6. Hook always exits 0 (never blocks)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/track-subagent-edits.sh"

pass=0
fail=0

TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

# Override ledger dir to tmp for tests
export HOME="$TMP_DIR"

run_test() {
    local desc="$1"
    local expected="$2"  # "0" = allow (no deny), "2" = deny
    local input="$3"

    local stdout exit_code
    stdout=$(printf '%s' "$input" | bash "$GUARD" 2>/dev/null || true)

    local outcome
    if printf '%s' "$stdout" | grep -q '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"'; then
        outcome="2"
    else
        outcome="0"
    fi

    if [ "$outcome" = "$expected" ]; then
        printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s — expected %s (deny=2/allow=0), got %s\n  stdout: %s\n' \
            "$desc" "$expected" "$outcome" "$stdout"
        fail=$((fail + 1))
    fi
}

assert_ledger_contains() {
    local desc="$1"
    local session_id="$2"
    local agent_id="$3"
    local expected_path="$4"

    local ledger="$TMP_DIR/.claude/post-format/${session_id}_${agent_id}.txt"
    if [ -f "$ledger" ] && grep -qF "$expected_path" "$ledger"; then
        printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s — ledger %s does not contain %s\n  ledger contents: %s\n' \
            "$desc" "$ledger" "$expected_path" "$(cat "$ledger" 2>/dev/null || echo "(missing)")"
        fail=$((fail + 1))
    fi
}

assert_ledger_absent() {
    local desc="$1"
    local session_id="$2"
    local agent_id_pattern="$3"

    local ledger_dir="$TMP_DIR/.claude/post-format"
    if ls "$ledger_dir"/*"${session_id}"* 2>/dev/null | grep -q .; then
        printf 'FAIL: %s — unexpected ledger files found for session %s\n' "$desc" "$session_id"
        fail=$((fail + 1))
    else
        printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    fi
}

# Test 1: Edit by subagent — always allows AND writes to ledger
EDIT_INPUT=$(jq -n \
    --arg fp "/app/lib/foo.ex" \
    '{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":$fp},"agent_type":"developer-phoenix-backend","agent_id":"agent-001","session_id":"sess-001"}')
run_test "subagent Edit always allows (never blocks)" "0" "$EDIT_INPUT"
assert_ledger_contains "subagent Edit appends file path to ledger" "sess-001" "agent-001" "/app/lib/foo.ex"

# Test 2: Write by subagent — writes to ledger
WRITE_INPUT=$(jq -n \
    --arg fp "/app/lib/bar.ex" \
    '{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":$fp},"agent_type":"developer-phoenix-backend","agent_id":"agent-002","session_id":"sess-002"}')
run_test "subagent Write always allows" "0" "$WRITE_INPUT"
assert_ledger_contains "subagent Write appends file path to ledger" "sess-002" "agent-002" "/app/lib/bar.ex"

# Test 3: MultiEdit by subagent — writes to ledger
MULTIEDIT_INPUT=$(jq -n \
    --arg fp "/app/lib/baz.ex" \
    '{"hook_event_name":"PreToolUse","tool_name":"MultiEdit","tool_input":{"file_path":$fp},"agent_type":"developer-phoenix-backend","agent_id":"agent-003","session_id":"sess-003"}')
run_test "subagent MultiEdit always allows" "0" "$MULTIEDIT_INPUT"
assert_ledger_contains "subagent MultiEdit appends file path to ledger" "sess-003" "agent-003" "/app/lib/baz.ex"

# Test 4: Orchestrator (empty agent_id) — allows but does NOT write to ledger
ORCH_INPUT=$(jq -n \
    --arg fp "/app/codegen/logging/session.md" \
    '{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":$fp},"agent_type":"","agent_id":"","session_id":"sess-004"}')
run_test "orchestrator Edit always allows" "0" "$ORCH_INPUT"
assert_ledger_absent "orchestrator Edit does NOT write ledger" "sess-004" ""

# Test 5: Bash tool — not a file-edit, allows and does NOT write to ledger
BASH_INPUT=$(jq -n \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"mix test"},"agent_type":"developer-phoenix-backend","agent_id":"agent-005","session_id":"sess-005"}')
run_test "Bash tool always allows (not tracked)" "0" "$BASH_INPUT"
assert_ledger_absent "Bash tool does NOT write ledger" "sess-005" ""

# Test 6: Second Edit by same subagent — BOTH paths appear in ledger (accumulation)
SECOND_EDIT=$(jq -n \
    --arg fp "/app/lib/second.ex" \
    '{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":$fp},"agent_type":"developer-phoenix-backend","agent_id":"agent-001","session_id":"sess-001"}')
run_test "second subagent Edit also allows" "0" "$SECOND_EDIT"
assert_ledger_contains "ledger accumulates multiple file paths" "sess-001" "agent-001" "/app/lib/second.ex"

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
