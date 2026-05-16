#!/bin/bash
# test-llm-hooks.sh — integration smoke for llm-test-guard.sh and llm-suite-guard.sh.
#
# Spawns each hook with sample stdin envelopes representing the user's footgun
# commands and asserts the refusal text names `make llm-single`.
#
# Exit 0: all checks pass.
# Non-zero: first failure with diagnostic.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS_DIR="$SCRIPT_DIR/../templates/shared/hooks"

LLM_TEST_GUARD="$HOOKS_DIR/llm-test-guard.sh"
LLM_SUITE_GUARD="$HOOKS_DIR/llm-suite-guard.sh"

REQUIRED_PHRASE="make llm-single"

pass=0
fail=0

check_refusal() {
    local desc="$1"
    local hook="$2"
    local input="$3"

    local stdout
    stdout=$(printf '%s' "$input" | bash "$hook" 2>/dev/null || true)

    # Must contain permissionDecision: deny
    if ! printf '%s' "$stdout" | grep -q '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"'; then
        printf 'FAIL: %s — hook did not deny\n  stdout: %s\n' "$desc" "$stdout"
        fail=$((fail + 1))
        return
    fi

    # Must contain the required phrase in the denial reason
    if ! printf '%s' "$stdout" | grep -q "$REQUIRED_PHRASE"; then
        printf 'FAIL: %s — denial reason does not mention "%s"\n  stdout: %s\n' \
            "$desc" "$REQUIRED_PHRASE" "$stdout"
        fail=$((fail + 1))
        return
    fi

    printf 'PASS: %s\n' "$desc"
    pass=$((pass + 1))
}

# Footgun 1: MIX_TEST_PARTITION=3 MIX_TEST_PARTITIONS=10 mix test --only llm_integration
# This is the exact command from the user's hour-long failure session.
FOOTGUN_PARTITION_CMD='MIX_TEST_PARTITION=3 MIX_TEST_PARTITIONS=10 mix test --only llm_integration'

check_refusal \
    "llm-test-guard: MIX_TEST_PARTITION=3 PARTITIONS=10 mix test --only llm_integration denied with make llm-single" \
    "$LLM_TEST_GUARD" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$FOOTGUN_PARTITION_CMD\"},\"agent_type\":\"developer-phoenix-backend\",\"agent_id\":\"smoke123\"}"

# Footgun 2: bare `make llm` from developer-phoenix-backend
check_refusal \
    "llm-suite-guard: bare make llm from developer-phoenix-backend denied with make llm-single" \
    "$LLM_SUITE_GUARD" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"make llm"},"agent_type":"developer-phoenix-backend","agent_id":"smoke123"}'

echo ""
echo "Integration smoke: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
