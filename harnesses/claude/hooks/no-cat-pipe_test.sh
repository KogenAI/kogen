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

    # Ambient CLAUDE_ROLE/AGENT_TYPE/PI_ROLE (e.g. the developer session
    # running this test suite carries CLAUDE_ROLE=build) must not leak into
    # the fixture — resolve_role()'s CLAUDE_ROLE > PI_ROLE precedence would
    # silently override a test's intended role.
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

    # Same ambient-leak isolation as run_test — strip CLAUDE_ROLE/AGENT_TYPE/
    # PI_ROLE from the outer shell before applying the test's explicit
    # env_prefix overrides.
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
# RED-then-GREEN proof: confirm a PRE-fix body (no ops-role check at all —
# the historical bug) denies ops unconditionally, then confirm the fixed
# working-tree body (Test 13 below) allows ops only.
#
# NOTE: this used to pull the "pre-fix" body via `git show HEAD:<file>`, but
# that self-invalidates the instant the fix lands at HEAD (`git show HEAD`
# then fetches the ALREADY-FIXED script and the RED branch can never fire —
# see context/bash-patterns.md "RED-then-GREEN proof via floating git show HEAD
# self-invalidates once fix lands"). Fixed by synthesizing the exact
# historical buggy body as a literal fixture instead of depending on git
# history. Written into a mktemp -d scratch dir (never into the live hooks
# source dir — a stray non-hook file there breaks `hook_registrations.py`'s
# HOOK-MANIFEST parity check and hangs around if the process is killed) with
# lib/ symlinked back so relative `dirname "$0"` sourcing of
# lib/hooks-lib.sh still resolves.
PRE_FIX_DIR="$(mktemp -d)"
ln -s "$SCRIPT_DIR/lib" "$PRE_FIX_DIR/lib"
PRE_FIX_NO_CAT_PIPE="$PRE_FIX_DIR/no-cat-pipe.pre-fix.sh"
trap 'rm -rf "$PRE_FIX_DIR"' EXIT
cat >"$PRE_FIX_NO_CAT_PIPE" <<'PREFIXEOF'
#!/bin/bash
# Synthetic pre-fix fixture: reproduces the historical bug where no-cat-pipe.sh
# had no ops-role check at all, so the cat-pipe pattern was denied for everyone
# including ops.
set -u
source "$(dirname "$0")/lib/hooks-lib.sh"
parse_input
debug_log no-cat-pipe "tool=$TOOL_NAME agent=$AGENT_TYPE cmd=$COMMAND"
if [ "$TOOL_NAME" != "Bash" ]; then
    exit 0
fi
if printf '%s' "$COMMAND" | grep -qE 'cat[[:space:]]+[^|]*\|[[:space:]]*(head|tail|grep|less|more)\b'; then
    deny "Use Read tool with offset/limit instead of \`cat | head/tail\`. Use Grep tool instead of \`cat | grep\`. Truncation hides relevant lines."
    exit 0
fi
exit 0
PREFIXEOF

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

# Test 13: CLAUDE_ROLE=ops + cat-pipe-in-ssh-arg — MUST ALLOW (bypass_roles)
FIXTURE_OPS_CAT_PIPE='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ssh box \"cat /etc/passwd | grep studio\""},"agent_type":"","agent_id":"a"}'
run_test_env "ops role bypasses cat-pipe guard" "0" "$FIXTURE_OPS_CAT_PIPE" "CLAUDE_ROLE=ops"

# Test 14: non-ops role + real UNQUOTED local cat-pipe — MUST STILL DENY
# (bypass doesn't leak). NOTE: FIXTURE_OPS_CAT_PIPE itself is now a quoted
# ssh remote payload — with the quote-strip fix (this pitch) it legitimately
# bypasses for ALL roles, ops or not (see Test 15/16 below), so it can no
# longer prove "bypass does not leak to non-ops". Use an unquoted local
# invocation instead to isolate the ops-bypass-roles behavior from the
# quote-strip behavior.
FIXTURE_LOCAL_CAT_PIPE='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"cat /etc/passwd | grep studio"},"agent_type":"","agent_id":"a"}'
run_test "non-ops role still denied for unquoted local cat-pipe (bypass does not leak)" "2" "$FIXTURE_LOCAL_CAT_PIPE"

# ── quote-strip fail-closed regression (this pitch) ─────────────────────────
# Test 15: ssh remote payload with cat-pipe inside quotes — ALLOW for ANY
# role (not a real local invocation; quoted span is stripped before match).
run_test "ssh remote cat-pipe payload (quoted) allowed" "0" "$FIXTURE_OPS_CAT_PIPE"

# Test 16: cat-pipe mentioned inside a quoted grep pattern — ALLOW (quoted
# string argument, not a real local invocation).
FIXTURE_QUOTED_GREP_ARG='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"grep -n \"cat foo | head\" notes.md"},"agent_type":"developer-phoenix-backend","agent_id":"a"}'
run_test "cat-pipe mentioned in quoted grep arg allowed" "0" "$FIXTURE_QUOTED_GREP_ARG"

# Test 17: real UNQUOTED local cat-pipe still denied unchanged (fail-closed
# direction sanity check, distinct from Test 12).
run_test "real unquoted cat-pipe still denied (fail-closed sanity)" "2" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"cat notes.md | head -20"},"agent_type":"developer-phoenix-backend","agent_id":"a"}'

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
