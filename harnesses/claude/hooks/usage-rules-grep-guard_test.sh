#!/bin/bash
# usage-rules-grep-guard_test.sh — unit tests for usage-rules-grep-guard.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/usage-rules-grep-guard.sh"

pass=0
fail=0

run_test() {
    local desc="$1"
    local expected="$2"
    local input="$3"

    # Capture stdout — the hook now emits a permissionDecision JSON envelope
    # to stdout for deny outcomes (exit 0) instead of stderr + exit 2. We
    # translate the legacy expected values: "2" means "expect deny",
    # "0" means "expect allow (no deny envelope)".
    local stdout
    stdout=$(printf '%s' "$input" | bash "$GUARD" 2>/dev/null || true)

    local outcome
    if printf '%s' "$stdout" | grep -q '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"'; then
        outcome="2"
    else
        outcome="0"
    fi

    if [ "$outcome" = "$expected" ]; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s — expected %s (deny=2/allow=0), got %s
  stdout: %s
' "$desc" "$expected" "$outcome" "$stdout"
        fail=$((fail + 1))
    fi
}

# Test 1: reviewer-phoenix grepping codegen/usage_rules/ — BLOCK
FIXTURE_REVIEWER_BLOCK='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"grep foo codegen/usage_rules/oban.md"},"agent_type":"reviewer-phoenix","agent_id":"abc"}'
run_test "reviewer-phoenix grep usage_rules blocks" "2" "$FIXTURE_REVIEWER_BLOCK"

# Test 1b: context-curator grepping codegen/usage_rules/ — BLOCK
FIXTURE_CURATOR_BLOCK='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"grep foo codegen/usage_rules/oban.md"},"agent_type":"context-curator","agent_id":"abc"}'
run_test "context-curator grep usage_rules blocks" "2" "$FIXTURE_CURATOR_BLOCK"

# Test 2: developer-phoenix-backend grepping codegen/usage_rules/ — ALLOW
# (real role name carries a stack suffix; bare "developer" never fires in
# production — this fixture exercises the actual developer-* match)
FIXTURE_DEV_ALLOW='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"grep foo codegen/usage_rules/oban.md"},"agent_type":"developer-phoenix-backend","agent_id":"abc"}'
run_test "developer-phoenix-backend grep usage_rules allows" "0" "$FIXTURE_DEV_ALLOW"

# Test 2b: developer-static grepping codegen/usage_rules/ — ALLOW
FIXTURE_DEV_STATIC_ALLOW='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"grep foo codegen/usage_rules/oban.md"},"agent_type":"developer-static","agent_id":"abc"}'
run_test "developer-static grep usage_rules allows" "0" "$FIXTURE_DEV_STATIC_ALLOW"

# Test 3: reviewer-phoenix grepping codegen/recipes/ — ALLOW
FIXTURE_RECIPES_ALLOW='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"grep foo codegen/recipes/INDEX.md"},"agent_type":"reviewer-phoenix","agent_id":"abc"}'
run_test "reviewer-phoenix grep recipes allows" "0" "$FIXTURE_RECIPES_ALLOW"

# Test 4: reviewer-phoenix using Grep tool on usage_rules path — BLOCK
FIXTURE_GREP_TOOL_BLOCK='{"hook_event_name":"PreToolUse","tool_name":"Grep","tool_input":{"pattern":"foo","path":"codegen/usage_rules/oban.md"},"agent_type":"reviewer-phoenix","agent_id":"abc"}'
run_test "reviewer-phoenix Grep tool on usage_rules blocks" "2" "$FIXTURE_GREP_TOOL_BLOCK"

# Test 4b: developer-phoenix-backend using Grep tool on usage_rules path — ALLOW
FIXTURE_GREP_TOOL_ALLOW='{"hook_event_name":"PreToolUse","tool_name":"Grep","tool_input":{"pattern":"foo","path":"codegen/usage_rules/oban.md"},"agent_type":"developer-phoenix-backend","agent_id":"abc"}'
run_test "developer-phoenix-backend Grep tool on usage_rules allows" "0" "$FIXTURE_GREP_TOOL_ALLOW"

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
