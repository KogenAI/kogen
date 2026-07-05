#!/usr/bin/env bash
# single-cycle-agent-in-flight_test.sh — hermetic tests for the
# single-cycle-agent-in-flight PreToolUse Agent hook.
#
# Auto-discovered by run-tests.sh (no Makefile wiring needed).
# No HOOK-MANIFEST header (test files are exempt from hook registration).

set -euo pipefail

HOOK="$(dirname "$0")/single-cycle-agent-in-flight.sh"
pass=0
fail=0

# ---------------------------------------------------------------------------
# Builders
# ---------------------------------------------------------------------------

# assistant Agent tool_use line with id
agent_spawn() {
    printf '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"%s","name":"Agent","input":{"subagent_type":"%s"}}]}}\n' "$1" "$2"
}

# user tool_result line referencing a tool_use id
agent_result() {
    printf '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"%s","content":"done"}]}}\n' "$1"
}

# hook stdin for a new Agent spawn
mk_input() {
    jq -n --arg s "$1" --arg t "$2" \
        '{"hook_event_name":"PreToolUse","tool_name":"Agent","tool_input":{"subagent_type":$s,"description":"x","prompt":"y"},"transcript_path":$t}'
}

# hook stdin for a non-Agent tool
mk_non_agent() {
    jq -n --arg t "$1" \
        '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"},"transcript_path":$t}'
}

# ---------------------------------------------------------------------------
# Assertion helpers
# ---------------------------------------------------------------------------

assert_allow() {
    local desc="$1"
    local input="$2"
    local env_prefix="${3:-}"
    local out
    out=$(echo "$input" | env -u CLAUDE_ROLE -u PI_ROLE ${env_prefix} bash "$HOOK" 2>/dev/null)
    if echo "$out" | grep -q '"permissionDecision"'; then
        echo "FAIL: $desc — expected ALLOW but got DENY"
        fail=$((fail + 1))
    else
        echo "PASS: $desc"
        pass=$((pass + 1))
    fi
}

assert_deny() {
    local desc="$1"
    local input="$2"
    local env_prefix="${3:-}"
    local out
    out=$(echo "$input" | env -u CLAUDE_ROLE -u PI_ROLE ${env_prefix} bash "$HOOK" 2>/dev/null)
    if echo "$out" | grep -q '"permissionDecision"'; then
        echo "PASS: $desc"
        pass=$((pass + 1))
    else
        echo "FAIL: $desc — expected DENY but got ALLOW"
        fail=$((fail + 1))
    fi
}

# ---------------------------------------------------------------------------
# Test cases
# ---------------------------------------------------------------------------

# T1: ALLOW — non-Agent tool (Bash) → exit 0 immediately
T=$(mktemp)
trap 'rm -f "$T"' EXIT
mk_non_agent "$T" | env -u CLAUDE_ROLE -u PI_ROLE bash "$HOOK" 2>/dev/null
echo "PASS: T1 non-Agent tool — allow"
pass=$((pass + 1))
trap - EXIT
rm -f "$T"

# T2: ALLOW — debug role bypass even with in-flight cycle agent
T=$(mktemp)
agent_spawn "toolu_01" "developer-phoenix-backend" >"$T"
INPUT=$(mk_input "developer-phoenix-backend" "$T")
out=$(echo "$INPUT" | CLAUDE_ROLE=debug bash "$HOOK" 2>/dev/null)
if echo "$out" | grep -q '"permissionDecision"'; then
    echo "FAIL: T2 debug role bypass — expected ALLOW but got DENY"
    fail=$((fail + 1))
else
    echo "PASS: T2 debug role bypass"
    pass=$((pass + 1))
fi
rm -f "$T"

# T3: ALLOW — shape role bypass
T=$(mktemp)
agent_spawn "toolu_02" "planner-phoenix" >"$T"
INPUT=$(mk_input "planner-phoenix" "$T")
out=$(echo "$INPUT" | CLAUDE_ROLE=shape bash "$HOOK" 2>/dev/null)
if echo "$out" | grep -q '"permissionDecision"'; then
    echo "FAIL: T3 shape role bypass — expected ALLOW but got DENY"
    fail=$((fail + 1))
else
    echo "PASS: T3 shape role bypass"
    pass=$((pass + 1))
fi
rm -f "$T"

# T4: ALLOW — ops role bypass
T=$(mktemp)
agent_spawn "toolu_03" "committer" >"$T"
INPUT=$(mk_input "committer" "$T")
out=$(echo "$INPUT" | CLAUDE_ROLE=ops bash "$HOOK" 2>/dev/null)
if echo "$out" | grep -q '"permissionDecision"'; then
    echo "FAIL: T4 ops role bypass — expected ALLOW but got DENY"
    fail=$((fail + 1))
else
    echo "PASS: T4 ops role bypass"
    pass=$((pass + 1))
fi
rm -f "$T"

# T5: ALLOW — new spawn subagent_type=Explore (non-cycle) even with in-flight
T=$(mktemp)
agent_spawn "toolu_04" "developer-phoenix-backend" >"$T"
assert_allow "T5 non-cycle type Explore" "$(mk_input "Explore" "$T")"
rm -f "$T"

# T6: ALLOW — new spawn subagent_type="" (empty, non-cycle)
T=$(mktemp)
agent_spawn "toolu_05" "developer-phoenix-backend" >"$T"
assert_allow "T6 empty subagent_type" "$(mk_input "" "$T")"
rm -f "$T"

# T7: ALLOW — new spawn subagent_type=general-purpose (non-cycle)
T=$(mktemp)
agent_spawn "toolu_06" "developer-phoenix-backend" >"$T"
assert_allow "T7 general-purpose subagent_type" "$(mk_input "general-purpose" "$T")"
rm -f "$T"

# T8: ALLOW — transcript unreadable → fail-open allow (even cycle type)
assert_allow "T8 transcript unreadable fail-open" "$(mk_input "developer-phoenix-backend" "/nonexistent/transcript.jsonl")"

# T9: ALLOW — empty transcript (no Agent spawns) + cycle type
T=$(mktemp)
assert_allow "T9 empty transcript no spawns" "$(mk_input "planner-phoenix" "$T")"
rm -f "$T"

# T10: ALLOW — prior Agent spawn COMPLETED (tool_use + matching tool_result)
T=$(mktemp)
agent_spawn "toolu_10" "planner-phoenix" >"$T"
agent_result "toolu_10" >>"$T"
assert_allow "T10 prior spawn completed" "$(mk_input "developer-phoenix-backend" "$T")"
rm -f "$T"

# T11: DENY — in-flight + new developer-phoenix-backend
T=$(mktemp)
agent_spawn "toolu_11" "planner-phoenix" >"$T"
assert_deny "T11 in-flight + developer-phoenix-backend" "$(mk_input "developer-phoenix-backend" "$T")"
rm -f "$T"

# T12: DENY — in-flight + new planner-phoenix
T=$(mktemp)
agent_spawn "toolu_12" "developer-phoenix-backend" >"$T"
assert_deny "T12 in-flight + planner-phoenix" "$(mk_input "planner-phoenix" "$T")"
rm -f "$T"

# T13: DENY — in-flight + new planner-static
T=$(mktemp)
agent_spawn "toolu_13" "developer-phoenix-backend" >"$T"
assert_deny "T13 in-flight + planner-static" "$(mk_input "planner-static" "$T")"
rm -f "$T"

# T14: DENY — in-flight + new developer-phoenix-frontend
T=$(mktemp)
agent_spawn "toolu_14" "planner-phoenix" >"$T"
assert_deny "T14 in-flight + developer-phoenix-frontend" "$(mk_input "developer-phoenix-frontend" "$T")"
rm -f "$T"

# T15: DENY — in-flight + new developer-static
T=$(mktemp)
agent_spawn "toolu_15" "planner-phoenix" >"$T"
assert_deny "T15 in-flight + developer-static" "$(mk_input "developer-static" "$T")"
rm -f "$T"

# T16: DENY — in-flight + new reviewer-phoenix
T=$(mktemp)
agent_spawn "toolu_16" "developer-phoenix-backend" >"$T"
assert_deny "T16 in-flight + reviewer-phoenix" "$(mk_input "reviewer-phoenix" "$T")"
rm -f "$T"

# T17: DENY — in-flight + new reviewer-static
T=$(mktemp)
agent_spawn "toolu_17" "developer-static" >"$T"
assert_deny "T17 in-flight + reviewer-static" "$(mk_input "reviewer-static" "$T")"
rm -f "$T"

# T18: DENY — in-flight + new context-curator
T=$(mktemp)
agent_spawn "toolu_18" "reviewer-phoenix" >"$T"
assert_deny "T18 in-flight + context-curator" "$(mk_input "context-curator" "$T")"
rm -f "$T"

# T19: DENY — in-flight + new committer
T=$(mktemp)
agent_spawn "toolu_19" "context-curator" >"$T"
assert_deny "T19 in-flight + committer" "$(mk_input "committer" "$T")"
rm -f "$T"

# T20: ALLOW — two prior spawns BOTH completed + new cycle spawn (regression)
T=$(mktemp)
agent_spawn "toolu_20a" "planner-phoenix" >"$T"
agent_result "toolu_20a" >>"$T"
agent_spawn "toolu_20b" "developer-phoenix-backend" >>"$T"
agent_result "toolu_20b" >>"$T"
assert_allow "T20 two prior spawns both completed" "$(mk_input "reviewer-phoenix" "$T")"
rm -f "$T"

# T21: DENY — two prior spawns, one completed one in-flight + new cycle spawn
T=$(mktemp)
agent_spawn "toolu_21a" "planner-phoenix" >"$T"
agent_result "toolu_21a" >>"$T"
agent_spawn "toolu_21b" "developer-phoenix-backend" >>"$T"
# toolu_21b has NO matching tool_result → in flight
assert_deny "T21 one completed one in-flight" "$(mk_input "reviewer-phoenix" "$T")"
rm -f "$T"

# T22: DENY — CLAUDE_ROLE=build with in-flight cycle agent (explicit build role enforces)
T=$(mktemp)
agent_spawn "toolu_22" "planner-phoenix" >"$T"
INPUT=$(mk_input "developer-phoenix-backend" "$T")
out=$(echo "$INPUT" | CLAUDE_ROLE=build bash "$HOOK" 2>/dev/null)
if echo "$out" | grep -q '"permissionDecision"'; then
    echo "PASS: T22 build role — in-flight still denies"
    pass=$((pass + 1))
else
    echo "FAIL: T22 build role — expected DENY but got ALLOW"
    fail=$((fail + 1))
fi
rm -f "$T"

# T23: DENY — empty role (CLAUDE_ROLE/PI_ROLE unset) with in-flight cycle agent
T=$(mktemp)
agent_spawn "toolu_23" "planner-phoenix" >"$T"
INPUT=$(mk_input "developer-phoenix-backend" "$T")
out=$(echo "$INPUT" | env -u CLAUDE_ROLE -u PI_ROLE bash "$HOOK" 2>/dev/null)
if echo "$out" | grep -q '"permissionDecision"'; then
    echo "PASS: T23 empty role — in-flight still denies"
    pass=$((pass + 1))
else
    echo "FAIL: T23 empty role — expected DENY but got ALLOW"
    fail=$((fail + 1))
fi
rm -f "$T"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: $pass passed, $fail failed"
[ "$fail" -gt 0 ] && exit 1
exit 0
