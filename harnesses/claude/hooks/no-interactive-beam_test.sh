#!/bin/bash
# no-interactive-beam_test.sh — unit tests for no-interactive-beam.sh
#
# Tests:
#   1: bare `erl -eval '...'` (no -noshell)            → deny
#   2: bare `erl -run foo bar` (no -noshell)            → deny
#   3: bare interactive `iex` (no -e/--eval)            → deny
#   4: `erl -noshell -eval '...' -s init stop`          → allow
#   5: `erl -noshell -eval '...halt().'`                → allow
#   6: `elixir -e '...'`                                → allow
#   7: `iex -e '...'`                                   → allow
#   8: `iex --eval '...'`                               → allow
#   9: `make test`                                      → allow
#  10: `mix compile`                                    → allow
#  11: Read tool with erl -eval command                 → allow (non-Bash)
#  12: codegen-log write narrating "erl -eval" in body  → allow
#  13: quoted erl -eval mention (grep arg)                → allow
#  14: bypass_roles: CLAUDE_ROLE=debug                   → allow
#  15: bypass_roles: CLAUDE_ROLE=shape                   → allow
#  16: bypass_roles: CLAUDE_ROLE=ops                     → allow
#  17: real unquoted erl -eval still denied (sanity)      → deny

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/no-interactive-beam.sh"

pass=0
fail=0

run_test() {
    local desc="$1"
    local expected="$2"
    local input="$3"

    # Ambient CLAUDE_ROLE/AGENT_TYPE/PI_ROLE must not leak into the fixture —
    # resolve_role()'s CLAUDE_ROLE > PI_ROLE precedence would silently
    # override a test's intended (unset) role.
    local stdout
    stdout=$(printf '%s' "$input" | env -u CLAUDE_ROLE -u AGENT_TYPE -u PI_ROLE bash "$GUARD" 2>/dev/null || true)

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

run_test_env() {
    local desc="$1"
    local expected="$2"
    local input="$3"
    shift 3
    local env_prefix=""
    for kv in "$@"; do
        env_prefix="$kv $env_prefix"
    done

    local stdout
    stdout=$(printf '%s' "$input" | env -u CLAUDE_ROLE -u AGENT_TYPE -u PI_ROLE $env_prefix bash "$GUARD" 2>/dev/null || true)

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

# Test 1: bare erl -eval (no -noshell) → deny (the F6 hang)
run_test "bare erl -eval (no -noshell) denied" "2" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"erl -eval '"'"'io:format(\"hi\")'"'"'"},"agent_type":"developer-phoenix-backend","agent_id":"a"}'

# Test 2: bare erl -run (no -noshell) → deny
run_test "bare erl -run (no -noshell) denied" "2" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"erl -run foo bar"},"agent_type":"developer-phoenix-backend","agent_id":"a"}'

# Test 3: bare interactive iex (no -e/--eval) → deny
run_test "bare interactive iex denied" "2" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"iex -S mix"},"agent_type":"developer-phoenix-backend","agent_id":"a"}'

# Test 4: erl -noshell -eval ... -s init stop → allow
run_test "erl -noshell -eval -s init stop allowed" "0" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"erl -noshell -eval '"'"'io:format(\"hi\")'"'"' -s init stop"},"agent_type":"developer-phoenix-backend","agent_id":"a"}'

# Test 5: erl -noshell -eval ... halt(). → allow
run_test "erl -noshell -eval halt() allowed" "0" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"erl -noshell -eval '"'"'io:format(\"~s\",[erlang:system_info(otp_release)]),halt().'"'"'"},"agent_type":"developer-phoenix-backend","agent_id":"a"}'

# Test 6: elixir -e '...' → allow (evaluates and exits)
run_test "elixir -e allowed" "0" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"elixir -e '"'"'IO.puts(1+1)'"'"'"},"agent_type":"developer-phoenix-backend","agent_id":"a"}'

# Test 7: iex -e '...' → allow
run_test "iex -e allowed" "0" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"iex -e '"'"'IO.puts(1)'"'"'"},"agent_type":"developer-phoenix-backend","agent_id":"a"}'

# Test 8: iex --eval '...' → allow
run_test "iex --eval allowed" "0" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"iex --eval '"'"'IO.puts(1)'"'"'"},"agent_type":"developer-phoenix-backend","agent_id":"a"}'

# Test 9: make test → allow
run_test "make test allowed" "0" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"make test"},"agent_type":"developer-phoenix-backend","agent_id":"a"}'

# Test 10: mix compile → allow
run_test "mix compile allowed" "0" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"mix compile"},"agent_type":"developer-phoenix-backend","agent_id":"a"}'

# Test 11: Read tool with erl -eval command → allow (non-Bash)
run_test "Read tool with erl -eval payload allowed" "0" \
    '{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"command":"erl -eval '"'"'x'"'"'"},"agent_type":"developer-phoenix-backend","agent_id":"a"}'

# Test 12: codegen-log write narrating "erl -eval" in heredoc body → allow
run_test "codegen-log write narrating erl -eval allowed" "0" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"codegen-log section --slug test --body @- <<EOF\n## developer-phoenix-backend Section\nSelf-corrected erl -eval to -noshell form.\nEOF"},"agent_type":"developer-phoenix-backend","agent_id":"a"}'

# Test 13: quoted erl -eval mention (grep arg) → allow
run_test "quoted erl -eval mention allowed" "0" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"grep -n \"erl -eval\" notes.md"},"agent_type":"developer-phoenix-backend","agent_id":"a"}'

# Test 14: CLAUDE_ROLE=debug → allow (bypass_roles)
FIXTURE_ROLE_ERL='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"erl -eval '"'"'io:format(\"x\")'"'"'"},"agent_type":"","agent_id":"a"}'
run_test_env "bypass_roles debug allowed" "0" "$FIXTURE_ROLE_ERL" "CLAUDE_ROLE=debug"

# Test 15: CLAUDE_ROLE=shape → allow (bypass_roles)
run_test_env "bypass_roles shape allowed" "0" "$FIXTURE_ROLE_ERL" "CLAUDE_ROLE=shape"

# Test 16: CLAUDE_ROLE=ops → allow (bypass_roles)
run_test_env "bypass_roles ops allowed" "0" "$FIXTURE_ROLE_ERL" "CLAUDE_ROLE=ops"

# Test 17: real unquoted erl -eval still denied (sanity, distinct from bypass)
run_test "real unquoted erl -eval still denied (sanity)" "2" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"erl -eval '"'"'io:format(\"x\")'"'"'"},"agent_type":"developer-phoenix-backend","agent_id":"a"}'

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
