#!/bin/bash
# no-cat-pipe_test.sh — unit tests for no-cat-pipe.sh
#
# Tests:
#   1: cat file | head → deny
#   2: cat file | tail → deny
#   3: cat file | grep foo → deny
#   4: cat file | less → deny
#   5: cat file | more → deny
#   6: cat file.txt → allow (no pipe)
#   7: echo x | cat → allow (cat is consumer, not source)
#   8: cat <<EOF heredoc → allow
#   9: cat a.txt b.txt → allow (multi-file, no pipe)
#  10: non-Bash tool → allow

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/no-cat-pipe.sh"

pass=0
fail=0

run_test() {
    local desc="$1"
    local expected="$2"
    local input="$3"

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

# Like run_test but accepts extra env vars as "KEY=value" strings (4th+ args).
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
    stdout=$(printf '%s' "$input" | env $env_prefix bash "$GUARD" 2>/dev/null || true)

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

run_test "cat file | head blocked" "2" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"cat foo.txt | head -50"},"agent_type":"developer-phoenix-backend","agent_id":"a"}'

run_test "cat file | tail blocked" "2" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"cat foo.txt | tail -20"},"agent_type":"developer-phoenix-backend","agent_id":"a"}'

run_test "cat file | grep blocked" "2" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"cat foo.txt | grep bar"},"agent_type":"developer-phoenix-backend","agent_id":"a"}'

run_test "cat file | less blocked" "2" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"cat foo.txt | less"},"agent_type":"developer-phoenix-backend","agent_id":"a"}'

run_test "cat file | more blocked" "2" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"cat foo.txt | more"},"agent_type":"developer-phoenix-backend","agent_id":"a"}'

run_test "cat file alone allowed" "0" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"cat foo.txt"},"agent_type":"developer-phoenix-backend","agent_id":"a"}'

run_test "echo x | cat allowed (cat is consumer)" "0" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"echo hello | cat"},"agent_type":"developer-phoenix-backend","agent_id":"a"}'

run_test "cat heredoc allowed" "0" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"cat <<EOF\nhello\nEOF"},"agent_type":"developer-phoenix-backend","agent_id":"a"}'

run_test "cat multi-file no pipe allowed" "0" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"cat a.txt b.txt"},"agent_type":"developer-phoenix-backend","agent_id":"a"}'

run_test "non-Bash tool allowed" "0" \
    '{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"command":"cat foo | head"},"agent_type":"developer-phoenix-backend","agent_id":"a"}'

# Test 11: codegen-log write narrating "cat foo | head" in heredoc body → allow
run_test "codegen-log write narrating cat pipe allowed" "0" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"codegen-log section --slug test --body @- <<EOF\n## developer-phoenix-backend Section\nUsed Read tool instead of cat foo.txt | head -50 — no truncation.\nEOF"},"agent_type":"developer-phoenix-backend","agent_id":"a"}'

# Test 12: real standalone cat pipe still blocked unchanged
run_test "real cat pipe still blocked (unchanged)" "2" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"cat foo.txt | head -50"},"agent_type":"developer-phoenix-backend","agent_id":"a"}'

# ── ops bypass_roles regression ─────────────────────────────────────────────
# RED-then-GREEN proof: confirm the PRE-fix committed body denies ops
# unconditionally (no role check at all), then confirm the fixed
# (post-`make install` regenerated) working-tree body allows ops only.
# Written INTO SCRIPT_DIR (not /tmp) so relative `dirname "$0"` sourcing of
# lib/hooks-lib.sh still resolves.
PRE_FIX_NO_CAT_PIPE="$SCRIPT_DIR/.no-cat-pipe.pre-fix.sh"
trap 'rm -f "$PRE_FIX_NO_CAT_PIPE"' EXIT
git -C "$SCRIPT_DIR" show HEAD:harnesses/claude/hooks/no-cat-pipe.sh >"$PRE_FIX_NO_CAT_PIPE" 2>/dev/null || true

if [ -s "$PRE_FIX_NO_CAT_PIPE" ]; then
    FIXTURE_RED_OPS_CAT='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ssh box \"cat /etc/passwd | grep studio\""},"agent_type":"","agent_id":"a"}'
    pre_fix_stdout=$(printf '%s' "$FIXTURE_RED_OPS_CAT" |
        env CLAUDE_ROLE=ops bash "$PRE_FIX_NO_CAT_PIPE" 2>/dev/null || true)
    if printf '%s' "$pre_fix_stdout" | grep -q '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"'; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS (RED): pre-fix body denies ops cat-pipe (no role check confirmed)\n'
        pass=$((pass + 1))
    else
        printf 'FAIL (RED): pre-fix body did NOT deny ops cat-pipe — RED proof invalid\n'
        fail=$((fail + 1))
    fi
fi

# Test 13: CLAUDE_ROLE=ops + cat-pipe-in-ssh-arg — MUST ALLOW (bypass_roles)
FIXTURE_OPS_CAT_PIPE='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ssh box \"cat /etc/passwd | grep studio\""},"agent_type":"","agent_id":"a"}'
run_test_env "ops role bypasses cat-pipe guard" "0" "$FIXTURE_OPS_CAT_PIPE" "CLAUDE_ROLE=ops"

# Test 14: non-ops role + same command — MUST STILL DENY (bypass doesn't leak)
run_test "non-ops role still denied for cat-pipe (bypass does not leak)" "2" "$FIXTURE_OPS_CAT_PIPE"

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
