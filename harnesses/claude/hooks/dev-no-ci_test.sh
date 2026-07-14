#!/bin/bash
# dev-no-ci_test.sh — unit tests for dev-no-ci.sh
#
# Tests:
#   1:    make ci ALLOWED (it's the loop's own gate command, do NOT deny)
# Test 2:    make test DENIED (expensive full-suite target, unowned by per-cycle iteration)
#   3-9:  gate commands / bare mix test / flags-only mix test → deny (2)
#   10-12: mix test with specific file path → allow (0)
#   13:   non-Bash tool → allow (0)
#   14:   non-developer-* agent → allow (0)
#   15:   mix test --cover with file path → allow (0)  [single-file coverage OK]
#   16:   mix coveralls → deny (2)
#   17:   mix coveralls.html → deny (2)
#   18:   mix coveralls.json → deny (2)
#   19:   mix test --trace flag-only → deny (2)
#   20:   mix test --trace with path → allow (0)
#   21:   bare mix test --cover (no path) → deny (2)
#   24-30: unowned expensive full-suite targets (test-stacks*, test-all,
#          test-coverage, test-hermetic, bench) → deny (2)
#   31:   make install ALLOWED
#   32-35: narrow targeted checks (hook-parity, enforce-registry-parity,
#          harness-parity, test-generator, rule-render-freshness) → allow (0)
#   37:   make ci-fast → deny (2)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/dev-no-ci.sh"

pass=0
fail=0

run_test() {
    local desc="$1"
    local expected="$2"
    local input="$3"

    # Capture stdout — the hook emits a permissionDecision JSON envelope
    # to stdout for deny outcomes (exit 0) instead of stderr + exit 2.
    # Translate legacy expected values: "2" means "expect deny",
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
        printf 'FAIL: %s — expected %s (deny=2/allow=0), got %s\n  stdout: %s\n' \
            "$desc" "$expected" "$outcome" "$stdout"
        fail=$((fail + 1))
    fi
}

# Test 1: make ci → ALLOW (loop's own gate command — do NOT deny)
run_test "make ci allowed for developer-phoenix-backend (loop gate command)" "0" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"make ci"},"agent_type":"developer-phoenix-backend","agent_id":"abc123"}'

# Test 2: make test → DENY (full-suite target, unowned by per-cycle iteration)
run_test "make test blocked (full-suite target)" "2" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"make test"},"agent_type":"developer-phoenix-backend","agent_id":"abc123"}'

# Test 3: make ci-cover → deny
run_test "make ci-cover blocked for developer-phoenix-backend" "2" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"make ci-cover"},"agent_type":"developer-phoenix-backend","agent_id":"abc123"}'

# Test 4: make predeploy → deny
run_test "make predeploy blocked for developer-phoenix-backend" "2" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"make predeploy"},"agent_type":"developer-phoenix-backend","agent_id":"abc123"}'

# Test 5: make llm → deny
run_test "make llm blocked for developer-phoenix-backend" "2" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"make llm"},"agent_type":"developer-phoenix-backend","agent_id":"abc123"}'

# Test 6: make llm-phoenix → deny
run_test "make llm-phoenix blocked for developer-phoenix-backend" "2" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"make llm-phoenix"},"agent_type":"developer-phoenix-backend","agent_id":"abc123"}'

# Test 7: make llm-all → deny
run_test "make llm-all blocked for developer-phoenix-backend" "2" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"make llm-all"},"agent_type":"developer-phoenix-backend","agent_id":"abc123"}'

# Test 8: bare mix test → deny
run_test "bare mix test blocked for developer-phoenix-backend" "2" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"mix test"},"agent_type":"developer-phoenix-backend","agent_id":"abc123"}'

# Test 9: mix test with only flags (no path) → deny
run_test "mix test flags-only blocked for developer-phoenix-backend" "2" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"mix test --trace --max-cases 1"},"agent_type":"developer-phoenix-backend","agent_id":"abc123"}'

# Test 10: mix test with specific file → allow
run_test "mix test specific file allowed for developer-phoenix-backend" "0" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"mix test test/foo/bar_test.exs"},"agent_type":"developer-phoenix-backend","agent_id":"abc123"}'

# Test 11: mix test with specific file and line → allow
run_test "mix test file:line allowed for developer-phoenix-backend" "0" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"mix test test/foo/bar_test.exs:42"},"agent_type":"developer-phoenix-backend","agent_id":"abc123"}'

# Test 12: mix test with specific file and --trace → allow
run_test "mix test file --trace allowed for developer-phoenix-backend" "0" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"mix test test/foo/bar_test.exs --trace"},"agent_type":"developer-phoenix-backend","agent_id":"abc123"}'

# Test 13: non-Bash tool (Read) → allow even if command looks like make ci
run_test "make ci on Read tool allowed (non-Bash)" "0" \
    '{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"command":"make ci"},"agent_type":"developer-phoenix-backend","agent_id":"abc123"}'

# Test 14: make ci for committer → allow (non-developer-*)
run_test "make ci allowed for committer (non-developer-*)" "0" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"make ci"},"agent_type":"committer","agent_id":"abc123"}'

# Coverage cases
# Test 15: mix test --cover with file path → allow (single-file coverage permitted)
run_test "mix test --cover with file path allowed for developer" "0" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"mix test --cover test/foo_test.exs"},"agent_type":"developer-phoenix-backend","agent_id":"abc123"}'

# Test 16: mix coveralls → deny
run_test "mix coveralls blocked for developer" "2" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"mix coveralls"},"agent_type":"developer-phoenix-backend","agent_id":"abc123"}'

# Test 17: mix coveralls.html → deny (matches coveralls.html artifact pattern)
run_test "mix coveralls.html blocked for developer" "2" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"mix coveralls.html"},"agent_type":"developer-phoenix-backend","agent_id":"abc123"}'

# Test 18: mix coveralls.json → deny
run_test "mix coveralls.json blocked for developer" "2" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"mix coveralls.json"},"agent_type":"developer-phoenix-backend","agent_id":"abc123"}'

# H5 thoroughness — bare `mix test --trace` flag-only is already denied by the
# existing flags-only regex (line 47 of dev-no-ci.sh). These cases verify the
# existing coverage and document what's covered:
#   - Test 9 covers `mix test --trace --max-cases 1` (multi-flag flags-only)
#   - Test 19 covers single-flag flags-only `mix test --trace`
#   - Test 20 covers `mix test --trace test/path.exs` (flag + path → allow)
# Test 19: mix test --trace flag-only → deny
run_test "mix test --trace flag-only blocked" "2" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"mix test --trace"},"agent_type":"developer-phoenix-backend","agent_id":"abc123"}'

# Test 20: mix test --trace test/path.exs → allow (flag + path)
run_test "mix test --trace with path allowed" "0" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"mix test --trace test/foo_test.exs"},"agent_type":"developer-phoenix-backend","agent_id":"abc123"}'

# Test 21: bare mix test --cover (no path) → deny
run_test "bare mix test --cover (no path) blocked for developer" "2" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"mix test --cover"},"agent_type":"developer-phoenix-backend","agent_id":"abc123"}'

# Test 22: codegen-log write narrating "make ci" in heredoc body → allow
run_test "codegen-log write narrating gated phrase allowed" "0" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"codegen-log section --slug test --body @- <<EOF\n## developer-phoenix-backend Section\nRan make ci, all green.\nEOF"},"agent_type":"developer-phoenix-backend","agent_id":"abc123"}'

# Test 23: real standalone make ci still allowed unchanged (loop gate command)
run_test "real make ci still allowed (unchanged)" "0" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"make ci"},"agent_type":"developer-phoenix-backend","agent_id":"abc123"}'

# Test 24: make test-stacks → deny (unowned, real LLM calls)
run_test "make test-stacks blocked for developer-phoenix-backend" "2" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"make test-stacks"},"agent_type":"developer-phoenix-backend","agent_id":"abc123"}'

# Test 25: make test-stacks-claude → deny
run_test "make test-stacks-claude blocked for developer-phoenix-backend" "2" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"make test-stacks-claude"},"agent_type":"developer-phoenix-backend","agent_id":"abc123"}'

# Test 26: make test-stacks-pi → deny
run_test "make test-stacks-pi blocked for developer-phoenix-backend" "2" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"make test-stacks-pi"},"agent_type":"developer-phoenix-backend","agent_id":"abc123"}'

# Test 27: make test-all → deny
run_test "make test-all blocked for developer-phoenix-backend" "2" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"make test-all"},"agent_type":"developer-phoenix-backend","agent_id":"abc123"}'

# Test 28: make test-coverage → deny
run_test "make test-coverage blocked for developer-phoenix-backend" "2" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"make test-coverage"},"agent_type":"developer-phoenix-backend","agent_id":"abc123"}'

# Test 29: make bench → deny
run_test "make bench blocked for developer-phoenix-backend" "2" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"make bench REASON=foo"},"agent_type":"developer-phoenix-backend","agent_id":"abc123"}'

# Test 30: make test-hermetic → deny (unowned full-suite target per pitch
# Scope — not the exact string threaded into the dev's prompt; only
# `make test` itself is threaded, per GATE_COMMAND in .claude/gate-config.sh)
run_test "make test-hermetic blocked for developer-phoenix-backend" "2" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"make test-hermetic"},"agent_type":"developer-phoenix-backend","agent_id":"abc123"}'

# Test 31: make install → allow
run_test "make install allowed for developer-phoenix-backend" "0" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"make install"},"agent_type":"developer-phoenix-backend","agent_id":"abc123"}'

# Test 32: make hook-parity → allow (narrow targeted check)
run_test "make hook-parity allowed for developer-phoenix-backend" "0" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"make hook-parity"},"agent_type":"developer-phoenix-backend","agent_id":"abc123"}'

# Test 33: make enforce-registry-parity → allow (narrow targeted check)
run_test "make enforce-registry-parity allowed for developer-phoenix-backend" "0" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"make enforce-registry-parity"},"agent_type":"developer-phoenix-backend","agent_id":"abc123"}'

# Test 34: make harness-parity → allow (narrow targeted check)
run_test "make harness-parity allowed for developer-phoenix-backend" "0" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"make harness-parity"},"agent_type":"developer-phoenix-backend","agent_id":"abc123"}'

# Test 35: make test-generator → allow (narrow targeted check)
run_test "make test-generator allowed for developer-phoenix-backend" "0" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"make test-generator"},"agent_type":"developer-phoenix-backend","agent_id":"abc123"}'

# Test 36: make rule-render-freshness → allow (narrow targeted check)
run_test "make rule-render-freshness allowed for developer-phoenix-backend" "0" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"make rule-render-freshness"},"agent_type":"developer-phoenix-backend","agent_id":"abc123"}'

# Test 37: make ci-fast → deny (restored; was in original deny list)
run_test "make ci-fast blocked for developer-phoenix-backend" "2" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"make ci-fast"},"agent_type":"developer-phoenix-backend","agent_id":"abc123"}'

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
