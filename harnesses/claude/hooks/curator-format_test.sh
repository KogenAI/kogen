#!/bin/bash
# curator-format_test.sh — unit tests for curator-format.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/curator-format.sh"

pass=0
fail=0

run_test() {
    local desc="$1"
    local expected="$2"
    local input="$3"

    local stdout
    stdout=$(printf '%s' "$input" | bash "$HOOK" 2>/dev/null || true)

    local outcome
    if printf '%s' "$stdout" | grep -q '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"'; then
        outcome="2"
    else
        outcome="0"
    fi

    if [ "$outcome" = "$expected" ]; then
        if [ -n "${VERBOSE:-}" ]; then
            printf 'PASS: %s\n' "$desc"
        fi
        pass=$((pass + 1))
    else
        printf 'FAIL: %s — expected %s (deny=2/allow=0), got %s\n  stdout: %s\n' \
            "$desc" "$expected" "$outcome" "$stdout"
        fail=$((fail + 1))
    fi
}

# Test 1: non-curator agent_type → no-op exits 0
FIXTURE_NOOP='{"hook_event_name":"SubagentStop","agent_type":"planner-phoenix","agent_id":"abc","session_id":"s1","cwd":"/tmp","stop_hook_active":false}'
run_test "non-curator agent_type is no-op" "0" "$FIXTURE_NOOP"

# Test 2: stop_hook_active=true → no-op exits 0
FIXTURE_ACTIVE='{"hook_event_name":"SubagentStop","agent_type":"context-curator","agent_id":"abc","session_id":"s1","cwd":"/tmp","stop_hook_active":true}'
run_test "stop_hook_active=true exits 0 immediately" "0" "$FIXTURE_ACTIVE"

# Test 3: context-curator with a Makefile format target → make format is called
MAKE_DIR="$(mktemp -d)"
cleanup() { rm -rf "$MAKE_DIR"; }
trap cleanup EXIT

# Makefile with a format target that creates a sentinel file
printf 'format:\n\ttouch .formatted\n' >"$MAKE_DIR/Makefile"

FIXTURE_CURATOR='{"hook_event_name":"SubagentStop","agent_type":"context-curator","agent_id":"abc","session_id":"s1","cwd":"'"$MAKE_DIR"'","stop_hook_active":false}'
printf '%s' "$FIXTURE_CURATOR" | bash "$HOOK" 2>/dev/null || true

if [ -f "$MAKE_DIR/.formatted" ]; then
    if [ -n "${VERBOSE:-}" ]; then
        printf 'PASS: context-curator with make format target — .formatted sentinel created\n'
    fi
    pass=$((pass + 1))
else
    printf 'FAIL: context-curator with make format target — .formatted sentinel NOT created\n'
    fail=$((fail + 1))
fi

# Test 4: context-curator with NO Makefile → exits 0 silently
NO_MAKE_DIR="$(mktemp -d)"
FIXTURE_NO_MAKE='{"hook_event_name":"SubagentStop","agent_type":"context-curator","agent_id":"abc","session_id":"s1","cwd":"'"$NO_MAKE_DIR"'","stop_hook_active":false}'
run_test "context-curator with no Makefile exits 0 silently" "0" "$FIXTURE_NO_MAKE"
rm -rf "$NO_MAKE_DIR"

# Test 5: context-curator stamps CURATED in cycle-state.json
CURATOR_CS_DIR="$(mktemp -d)"
mkdir -p "$CURATOR_CS_DIR/codegen/logging"
LOG_CS="$CURATOR_CS_DIR/codegen/logging/20260614_120000_feat_session.md"
printf '## context-curator Section\n\nDone.\n' >"$LOG_CS"
# Build transcript with a Write to the log (so session_log_from_transcript resolves it)
TRANSCRIPT_CS="$CURATOR_CS_DIR/transcript.jsonl"
printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"%s"}}]}}\n' \
    "$LOG_CS" >"$TRANSCRIPT_CS"
FIXTURE_CURATOR_CS=$(jq -n \
    --arg cwd "$CURATOR_CS_DIR" \
    --arg t "$TRANSCRIPT_CS" \
    '{"hook_event_name":"SubagentStop","agent_type":"context-curator","agent_id":"abc","session_id":"test-cs","transcript_path":$t,"cwd":$cwd,"stop_hook_active":false}')
printf '%s' "$FIXTURE_CURATOR_CS" | bash "$HOOK" 2>/dev/null || true
cs_state=""
cs_file="$CURATOR_CS_DIR/codegen/gate-pending/cycle-state.json"
if [ -f "$cs_file" ]; then
    cs_state=$(jq -r '.state // ""' "$cs_file" 2>/dev/null || printf '')
fi
if [ "$cs_state" = "CURATED" ]; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: context-curator stamps CURATED in cycle-state.json\n'
    pass=$((pass + 1))
else
    printf 'FAIL: context-curator should stamp CURATED, got state=%s\n' "$cs_state"
    fail=$((fail + 1))
fi
rm -rf "$CURATOR_CS_DIR"

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
