#!/bin/bash
# dev-no-ci_test.sh — unit tests for dev-no-ci.sh
#
# Tests:
#   1:    make ci ALLOWED (never in a deny list; in a generated app it is the
#         configured gate, in codegen's Makefile `ci: test` is a pure alias)
# Test 2:    make test DENIED when the project declares no gate command
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
#   22:   MIX_ENV=test mix test --exclude slow (env-prefixed bare) → deny (2)
#   23:   MIX_ENV=test mix test --exclude slow test/path.exs (env-prefixed
#         with path) → allow (0)
#   24:   MIX_ENV=test mix test (env-prefixed, no args at all) → deny (2)
#   24-30: unowned expensive full-suite targets (test-stacks*, test-all,
#          test-coverage, test-hermetic, bench) → deny (2)
#   31:   make install ALLOWED
#   32-35: narrow targeted checks (hook-parity, enforce-registry-parity,
#          harness-parity, test-generator, rule-render-freshness) → allow (0)
#   37:   make ci-fast → deny (2)
#   38-49: the configured gate command (<project>/.claude/gate-config.sh
#          GATE_COMMAND, resolved through lib/gate-select.sh) is ALLOWED, the
#          expensive superset around it stays denied, and an absent/empty/
#          malformed config allows nothing extra.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/dev-no-ci.sh"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# The hook resolves the project's gate command from <cwd>/.claude/gate-config.sh,
# so every case must pin an explicit cwd or it would silently depend on where
# the suite happens to be invoked from. Cases that predate the gate allowance
# run against NOGATE_DIR — a project that declares no gate at all — which is
# exactly the "deny lists apply unchanged" baseline they were written for.
FIXTURE_ROOT="$(mktemp -d)"
trap 'rm -rf "$FIXTURE_ROOT"' EXIT

mk_gate_fixture() {
    # mk_gate_fixture <name> [<gate-config.sh body>]  → prints the dir
    local dir="$FIXTURE_ROOT/$1"
    mkdir -p "$dir/.claude"
    if [ "$#" -ge 2 ]; then
        printf '%s\n' "$2" >"$dir/.claude/gate-config.sh"
    fi
    printf '%s' "$dir"
}

NOGATE_DIR="$(mk_gate_fixture nogate)" # no .claude/gate-config.sh at all
GATE_TEST_DIR="$(mk_gate_fixture gatetest 'GATE_COMMAND="make test"')"
GATE_CI_DIR="$(mk_gate_fixture gateci 'GATE_COMMAND="make ci"')"
GATE_EMPTY_DIR="$(mk_gate_fixture gateempty 'GATE_COMMAND=""')"
GATE_BAD_DIR="$(mk_gate_fixture gatebad 'GATE_COMMAND="make test"
GATE_MODE=fast')"
rm -f "$NOGATE_DIR/.claude/gate-config.sh"

pass=0
fail=0

# hook_payload <command> <agent_type> <tool_name> <cwd>
hook_payload() {
    printf '{"hook_event_name":"PreToolUse","tool_name":"%s","tool_input":{"command":%s},"agent_type":"%s","agent_id":"abc123","cwd":"%s"}' \
        "$3" "$(printf '%s' "$1" | jq -Rs .)" "$2" "$4"
}

# run_gate_test <desc> <expected 0|2> <command> <cwd> [agent_type]
run_gate_test() {
    local desc="$1" expected="$2" cmd="$3" cwd="$4" agent="${5:-developer-phoenix-backend}"
    run_test "$desc" "$expected" "$(hook_payload "$cmd" "$agent" "Bash" "$cwd")"
}

run_test() {
    local desc="$1"
    local expected="$2"
    local input="$3"

    # Cases written before the gate allowance carry no "cwd" key; pin them to
    # the gate-less fixture so the resolver finds nothing and the deny lists
    # apply exactly as they did before.
    if ! printf '%s' "$input" | grep -q '"cwd"'; then
        input="${input%\}},\"cwd\":\"$NOGATE_DIR\"}"
    fi

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

# Test 2: make test → DENY when the project declares no gate command at all.
# (When it IS the declared gate, it is allowed — tests 38/39. The point of the
# deny list is cost the loop already owns, not the literal target name.)
run_test "make test blocked when project declares no gate command" "2" \
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

# Fault 2 regression — the env-prefixed bypass (`command_word_of_segment`
# skips leading VAR=val assignments, so `MIX_ENV=test mix test ...` must be
# denied identically to the unprefixed form).
# Test 22: MIX_ENV=test mix test --exclude slow (env-prefixed, flags-only) → deny
run_test "env-prefixed flags-only mix test blocked for developer" "2" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"MIX_ENV=test mix test --exclude slow"},"agent_type":"developer-phoenix-backend","agent_id":"abc123"}'

# Test 23: MIX_ENV=test mix test --exclude slow test/path.exs (env-prefixed,
# path present) → allow
run_test "env-prefixed mix test with path allowed for developer" "0" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"MIX_ENV=test mix test --exclude slow test/foo_test.exs"},"agent_type":"developer-phoenix-backend","agent_id":"abc123"}'

# Test 24: MIX_ENV=test mix test (env-prefixed, bare, no args at all) → deny
run_test "env-prefixed bare mix test blocked for developer" "2" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"MIX_ENV=test mix test"},"agent_type":"developer-phoenix-backend","agent_id":"abc123"}'

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

# ── The configured gate command is allowed; the superset around it is not ───
# The loop threads GATE_COMMAND verbatim into the developer's prompt
# (orchestration_loop.ex build_prompt/2, "Before handing back, run `<cmd>`
# yourself"). Denying that exact command told the developer to run something
# and then blocked it, burning a turn slot per attempt. These lock the two
# together and prove nothing else was let through.

# Test 38: gate is `make test` → `make test` ALLOWED (the reported bug)
run_gate_test "configured gate command 'make test' allowed" "0" \
    'make test' "$GATE_TEST_DIR"

# Test 39: the same, resolved against codegen's real .claude/gate-config.sh —
# guards the actual repo wiring, not just a synthetic fixture.
run_gate_test "codegen's own declared gate command allowed in-repo" "0" \
    'make test' "$REPO_ROOT"

# Test 40: gate command with trailing argv/redirection → still the same target,
# same cost, ALLOWED (a dev truncating gate output must not burn a turn).
run_gate_test "configured gate command with redirection allowed" "0" \
    'make test 2>&1 | tail -50' "$GATE_TEST_DIR"

# Test 41: expensive superset still DENIED even though it shares the prefix.
run_gate_test "make test-all still denied when gate is make test" "2" \
    'make test-all' "$GATE_TEST_DIR"

# Test 42: real-LLM pre-deploy gate still DENIED alongside a `make test` gate.
run_gate_test "make test-stacks still denied when gate is make test" "2" \
    'make test-stacks' "$GATE_TEST_DIR"

# Test 43: the gate command must not become a smuggling prefix for the
# expensive targets it sits next to in a shell chain.
run_gate_test "gate command chained into make llm-all denied" "2" \
    'make test && make llm-all' "$GATE_TEST_DIR"

# Test 44: GATE_COMMAND is per-PROJECT — a generated app declaring `make ci`
# (a strict superset there: credo/dialyzer/sobelow/audit) allows `make ci`…
run_gate_test "generated-app gate 'make ci' allowed" "0" \
    'make ci' "$GATE_CI_DIR"

# Test 45: …and `make test` stays denied there, because it is not that app's
# declared gate. Same hook, opposite verdict, driven only by the config.
run_gate_test "make test denied in an app whose gate is make ci" "2" \
    'make test' "$GATE_CI_DIR"

# Test 46: no .claude/gate-config.sh → nothing is allowed by the gate route,
# deny lists apply exactly as before (fail-safe, never fail-open).
run_gate_test "absent gate-config.sh denies make test" "2" \
    'make test' "$NOGATE_DIR"

# Test 47: present but empty GATE_COMMAND → gate-select.sh returns the
# __GATE_UNRESOLVED__ sentinel; treated as "no gate", not as "allow all".
run_gate_test "empty GATE_COMMAND denies make test" "2" \
    'make test' "$GATE_EMPTY_DIR"

# Test 48: malformed GATE_MODE makes gate-select.sh fail loud — the hook must
# inherit that failure as "unresolved", not silently allow the command.
run_gate_test "malformed GATE_MODE denies make test" "2" \
    'make test' "$GATE_BAD_DIR"

# Test 49: a non-developer agent is untouched by any of this.
run_gate_test "make test allowed for committer (non-developer-*)" "0" \
    'make test' "$GATE_CI_DIR" "committer"

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
