#!/bin/bash
# orchestrator-no-ci_test.sh — unit tests for orchestrator-no-ci.sh
#
# Tests:
#   1:  orchestrator make ci → deny (2)
#   2:  orchestrator make ci (duplicate) → deny (2)
#   3:  orchestrator make ci 2>&1 | tail -100 → deny (2)
#   4:  orchestrator make gate-status → allow (0) — INCONCLUSIVE recovery
#   5:  orchestrator make gate-logs → allow (0)
#   6:  orchestrator make gate-kill → allow (0)
#   7:  orchestrator make llm-phoenix → deny (2)
#   8:  orchestrator mix test (bare) → deny (2)
#   9:  orchestrator mix test test/foo_test.exs → deny (2) — orchestrator NEVER runs tests
#   10: developer-phoenix-backend make ci → allow (0) — dev-no-ci.sh owns this
#   11: reviewer-phoenix make ci → allow (0) — this hook only gates the orchestrator
#   12: subagent with non-empty agent_id, empty agent_type, make ci → allow (0)
#   13: CLAUDE_ROLE=ops make ci → allow (0) — ops bypass via resolve_role
#   15: CLAUDE_ROLE=experiment make ci → allow (0) — experiment bypass via resolve_role
#   19: CLAUDE_ROLE=babysit make ci → allow (0) — babysit bypass via resolve_role
#   20-29: the project's DECLARED gate command (.claude/gate-config.sh
#          GATE_COMMAND, resolved via lib/gate-select.sh) is denied to the
#          outer session under whatever name it carries, the hardcoded list
#          still applies, and every documented bypass still bypasses.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/orchestrator-no-ci.sh"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# The hook resolves the project's gate from <cwd>/.claude/gate-config.sh, so a
# case that pins no cwd would silently depend on where the suite was invoked
# from. Cases predating the resolved-gate block run against NOGATE_DIR — a
# project declaring no gate at all — which is the "hardcoded list applies
# unchanged" baseline they were written for.
FIXTURE_ROOT="$(mktemp -d)"
trap 'rm -rf "$FIXTURE_ROOT"' EXIT

mk_gate_fixture() {
    local dir="$FIXTURE_ROOT/$1"
    mkdir -p "$dir/.claude"
    if [ "$#" -ge 2 ]; then
        printf '%s\n' "$2" >"$dir/.claude/gate-config.sh"
    fi
    printf '%s' "$dir"
}

NOGATE_DIR="$(mk_gate_fixture nogate)"
GATE_TEST_DIR="$(mk_gate_fixture gatetest 'GATE_COMMAND="make test"')"
GATE_CI_DIR="$(mk_gate_fixture gateci 'GATE_COMMAND="make ci"')"
GATE_EMPTY_DIR="$(mk_gate_fixture gateempty 'GATE_COMMAND=""')"
rm -f "$NOGATE_DIR/.claude/gate-config.sh"

pass=0
fail=0

# run_gate_test <desc> <expected 0|2> <command> <cwd> [agent_type] [agent_id]
run_gate_test() {
    local desc="$1" expected="$2" cmd="$3" cwd="$4" agent="${5:-}" aid="${6:-}"
    run_test "$desc" "$expected" \
        "$(printf '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":%s},"agent_type":"%s","agent_id":"%s","cwd":"%s"}' \
            "$(printf '%s' "$cmd" | jq -Rs .)" "$agent" "$aid" "$cwd")"
}

run_test() {
    local desc="$1"
    local expected="$2"
    local input="$3"

    # Cases written before the resolved-gate block carry no "cwd" key; pin them
    # to the gate-less fixture so the resolver finds nothing and only the
    # hardcoded deny list applies — exactly what they were asserting.
    if ! printf '%s' "$input" | grep -q '"cwd"'; then
        input="${input%\}},\"cwd\":\"$NOGATE_DIR\"}"
    fi

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
        printf 'FAIL: %s — expected %s (deny=2/allow=0), got %s\n  stdout: %s\n' \
            "$desc" "$expected" "$outcome" "$stdout"
        fail=$((fail + 1))
    fi
}

# Orchestrator inputs: agent_type="" and agent_id="" (both absent/empty)

# Test 1: make ci → deny
run_test "orchestrator make ci → deny" "2" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"make ci"},"agent_type":"","agent_id":""}'

# Test 2: make ci (duplicate coverage) → deny
run_test "orchestrator make ci → deny (2)" "2" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"make ci"},"agent_type":"","agent_id":""}'

# Test 3: make ci 2>&1 | tail -100 → deny (pipe variant)
run_test "orchestrator make ci 2>&1 | tail -100 → deny" "2" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"make ci 2>&1 | tail -100"},"agent_type":"","agent_id":""}'

# Test 4: make gate-status → allow (INCONCLUSIVE recovery)
run_test "orchestrator make gate-status → allow" "0" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"make gate-status"},"agent_type":"","agent_id":""}'

# Test 5: make gate-logs → allow
run_test "orchestrator make gate-logs → allow" "0" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"make gate-logs"},"agent_type":"","agent_id":""}'

# Test 6: make gate-kill → allow
run_test "orchestrator make gate-kill → allow" "0" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"make gate-kill"},"agent_type":"","agent_id":""}'

# Test 7: make llm-phoenix → deny
run_test "orchestrator make llm-phoenix → deny" "2" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"make llm-phoenix"},"agent_type":"","agent_id":""}'

# Test 8: mix test (bare) → deny
run_test "orchestrator mix test bare → deny" "2" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"mix test"},"agent_type":"","agent_id":""}'

# Test 9: mix test test/foo_test.exs → deny (orchestrator NEVER runs tests)
run_test "orchestrator mix test specific file → deny" "2" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"mix test test/foo_test.exs"},"agent_type":"","agent_id":""}'

# Test 10: developer-phoenix-backend make ci → allow (dev-no-ci.sh owns this)
run_test "developer-phoenix-backend make ci → allow (skip)" "0" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"make ci"},"agent_type":"developer-phoenix-backend","agent_id":"abc123"}'

# Test 11: reviewer-phoenix make ci → allow (this hook only gates the orchestrator)
run_test "reviewer-phoenix make ci → allow (skip)" "0" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"make ci"},"agent_type":"reviewer-phoenix","agent_id":"xyz789"}'

# Test 12: subagent with non-empty agent_id but empty agent_type → allow (not orchestrator)
run_test "subagent non-empty agent_id empty agent_type make ci → allow (skip)" "0" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"make ci"},"agent_type":"","agent_id":"subagent999"}'

# Test 13: CLAUDE_ROLE=ops make ci → allow (ops bypass — live box inspection)
CLAUDE_ROLE=ops run_test "CLAUDE_ROLE=ops make ci → allow (ops bypass)" "0" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"make ci"},"agent_type":"","agent_id":""}'

# Test 15: CLAUDE_ROLE=experiment make ci → allow (experiment bypass — standalone dev session)
CLAUDE_ROLE=experiment run_test "CLAUDE_ROLE=experiment make ci → allow (experiment bypass)" "0" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"make ci"},"agent_type":"","agent_id":""}'

# Test 17: codegen-log write narrating "make ci" in heredoc body → allow
run_test "codegen-log write narrating gated phrase allowed" "0" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"codegen-log section --slug test --body @- <<EOF\n## orchestrator Section\nDelegated to developer; make ci ran green in the gate.\nEOF"},"agent_type":"","agent_id":""}'

# Test 18: real standalone make ci still denied unchanged
run_test "orchestrator real make ci still denied (unchanged)" "2" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"make ci"},"agent_type":"","agent_id":""}'

# Test 19: CLAUDE_ROLE=babysit make ci → allow (babysit bypass — dispatches codegen-build --queue)
CLAUDE_ROLE=babysit run_test "CLAUDE_ROLE=babysit make ci → allow (babysit bypass)" "0" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"make ci"},"agent_type":"","agent_id":""}'

# ── The declared gate command, under whatever name it carries ───────────────
# codegen's Makefile:194 is `ci: test`, so denying only `make ci` left the
# identical target reachable as `make test` — which is also codegen's actual
# GATE_COMMAND. The guard was bypassable by typing the other name.

# Test 20: the hole — codegen's real declared gate, resolved from the repo's
# own .claude/gate-config.sh, is now denied to the outer session.
run_gate_test "orchestrator denied codegen's declared gate (in-repo)" "2" \
    'make test' "$REPO_ROOT"

# Test 21: same via a synthetic fixture, so the case survives codegen changing
# its own GATE_COMMAND later.
run_gate_test "orchestrator denied gate 'make test' (fixture)" "2" \
    'make test' "$GATE_TEST_DIR"

# Test 22: redirection/pipe variant is the same run, same denial (mirrors the
# existing `make ci 2>&1 | tail -100` case).
run_gate_test "orchestrator denied gate with redirection" "2" \
    'make test 2>&1 | tail -100' "$GATE_TEST_DIR"

# Test 23: ADDITIVE, not a replacement — `make ci` stays denied in codegen even
# though the resolved gate is `make test`. It is the alias for the same target.
run_gate_test "make ci still denied when resolved gate is make test" "2" \
    'make ci' "$GATE_TEST_DIR"

# Test 24: in a generated app the resolved gate IS `make ci` — still denied,
# now by both routes. Same hook, same verdict, different reason.
run_gate_test "generated-app gate 'make ci' denied" "2" \
    'make ci' "$GATE_CI_DIR"

# Test 25: `make test` is NOT that app's gate and is not in the hardcoded list,
# so it stays allowed there — the hook denies the declared gate, not a name.
run_gate_test "make test allowed in an app whose gate is make ci" "0" \
    'make test' "$GATE_CI_DIR"

# Test 26: no .claude/gate-config.sh → resolver adds nothing, hardcoded list
# applies exactly as before. Nothing newly denied.
run_gate_test "absent gate-config.sh leaves make test allowed" "0" \
    'make test' "$NOGATE_DIR"

# Test 27: present but empty GATE_COMMAND → __GATE_UNRESOLVED__ sentinel,
# treated as "no gate", never as "deny everything".
run_gate_test "empty GATE_COMMAND leaves make test allowed" "0" \
    'make test' "$GATE_EMPTY_DIR"

# Test 28: gate MANAGEMENT stays reachable — the allowlist sits ahead of the
# resolved-gate block, which is how a wedged gate is still inspectable.
run_gate_test "make gate-status still allowed with a resolved gate" "0" \
    'make gate-status' "$GATE_TEST_DIR"

# Test 29: scope unchanged — a developer subagent running the gate is
# dev-no-ci.sh's business (it ALLOWS it; the loop tells the dev to run it).
# This hook must not reach across and deny it.
run_gate_test "developer subagent running the gate is not this hook's business" "0" \
    'make test' "$GATE_TEST_DIR" "developer-phoenix-backend" "abc123"

# Test 30: subagent identified by agent_id alone is likewise out of scope.
run_gate_test "subagent by agent_id only → skip" "0" \
    'make test' "$GATE_TEST_DIR" "" "subagent999"

# Tests 31-33: the documented outer-session escape hatches
# (context/launcher-hook-matrix.md) must still bypass the NEW denial, or a
# session that legitimately needs the suite would have no way to run it.
CLAUDE_ROLE=ops run_gate_test "CLAUDE_ROLE=ops bypasses the gate denial" "0" \
    'make test' "$GATE_TEST_DIR"
CLAUDE_ROLE=experiment run_gate_test "CLAUDE_ROLE=experiment bypasses the gate denial" "0" \
    'make test' "$GATE_TEST_DIR"
CLAUDE_ROLE=babysit run_gate_test "CLAUDE_ROLE=babysit bypasses the gate denial" "0" \
    'make test' "$GATE_TEST_DIR"

# Test 34: a codegen-log write narrating the gate command is a mention, not an
# invocation — the existing bypass must still win over the new denial.
run_gate_test "codegen-log write narrating the gate command allowed" "0" \
    'codegen-log section --slug test --body @- <<EOF
## orchestrator Section
Delegated to developer; make test ran green in the gate.
EOF' "$GATE_TEST_DIR"

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
