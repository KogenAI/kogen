#!/bin/bash
# no-silent-failure_test.sh — tests for no-silent-failure.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/no-silent-failure.sh"

PASS=0
FAIL=0

assert_eq() {
    local expected="$1" actual="$2" msg="$3"
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' "$msg" "$expected" "$actual"
    fi
}

run_hook() {
    # $1 = json payload
    printf '%s' "$1" | env -u CLAUDE_ROLE -u PI_ROLE bash "$HOOK"
}

is_denied() {
    printf '%s' "$1" | grep -q '"permissionDecision":[[:space:]]*"deny"'
}

# ---- DENY cases ----

out=$(run_hook '{"tool_name":"Edit","tool_input":{"file_path":"lib/foo.ts","old_string":"x","new_string":"try { doThing(); } catch {}"}}')
if is_denied "$out"; then PASS=$((PASS + 1)); else
    FAIL=$((FAIL + 1))
    echo "FAIL: empty catch {} (TS) should DENY: $out"
fi

out=$(run_hook '{"tool_name":"Edit","tool_input":{"file_path":"lib/foo.ts","old_string":"x","new_string":"try { doThing(); } catch (e) {}"}}')
if is_denied "$out"; then PASS=$((PASS + 1)); else
    FAIL=$((FAIL + 1))
    echo "FAIL: empty catch (e) {} (TS) should DENY: $out"
fi

out=$(run_hook '{"tool_name":"Write","tool_input":{"file_path":"lib/foo.py","content":"try:\n    do_thing()\nexcept:\n    pass\n"}}')
if is_denied "$out"; then PASS=$((PASS + 1)); else
    FAIL=$((FAIL + 1))
    echo "FAIL: bare except: + pass (Python) should DENY: $out"
fi

out=$(run_hook '{"tool_name":"Write","tool_input":{"file_path":"lib/foo.py","content":"try:\n    do_thing()\nexcept Exception:\n    pass\n"}}')
if is_denied "$out"; then PASS=$((PASS + 1)); else
    FAIL=$((FAIL + 1))
    echo "FAIL: except Exception: + pass (Python) should DENY: $out"
fi

out=$(run_hook '{"tool_name":"Edit","tool_input":{"file_path":"lib/foo.ex","old_string":"x","new_string":"rescue _ ->\n  :error\nend"}}')
if is_denied "$out"; then PASS=$((PASS + 1)); else
    FAIL=$((FAIL + 1))
    echo "FAIL: rescue _ -> w/o reraise (Elixir) should DENY: $out"
fi

out=$(run_hook '{"tool_name":"Edit","tool_input":{"file_path":"lib/foo.ex","old_string":"x","new_string":"rescue e ->\n  :error\nend"}}')
if is_denied "$out"; then PASS=$((PASS + 1)); else
    FAIL=$((FAIL + 1))
    echo "FAIL: rescue e -> (named var) w/o reraise (Elixir) should DENY: $out"
fi

out=$(run_hook '{"tool_name":"MultiEdit","tool_input":{"file_path":"lib/foo.ex","edits":[{"old_string":"a","new_string":"ok"},{"old_string":"b","new_string":"rescue _ ->\n  :error\nend"}]}}')
if is_denied "$out"; then PASS=$((PASS + 1)); else
    FAIL=$((FAIL + 1))
    echo "FAIL: MultiEdit concat with swallow token should DENY: $out"
fi

out=$(run_hook '{"tool_name":"Edit","tool_input":{"file_path":"lib/foo.ex","old_string":"x","new_string":"# fail-loud-exempt:\nrescue _ ->\n  :error\nend"}}')
if is_denied "$out"; then PASS=$((PASS + 1)); else
    FAIL=$((FAIL + 1))
    echo "FAIL: bare fail-loud-exempt (no reason) should still DENY: $out"
fi

# ---- ALLOW cases ----

out=$(run_hook '{"tool_name":"Edit","tool_input":{"file_path":"lib/foo.ex","old_string":"x","new_string":"# fail-loud-exempt: sourced helper fail-open by design\nrescue _ ->\n  :error\nend"}}')
if is_denied "$out"; then
    FAIL=$((FAIL + 1))
    echo "FAIL: exemption with reason should ALLOW: $out"
else PASS=$((PASS + 1)); fi

out=$(run_hook '{"tool_name":"Edit","tool_input":{"file_path":"lib/foo.ex","old_string":"x","new_string":"case v do\n  {:ok, r} -> {:ok, r}\n  {:error, reason} -> {:error, reason}\nend"}}')
if is_denied "$out"; then
    FAIL=$((FAIL + 1))
    echo "FAIL: {:error, reason} tagged tuple should ALLOW: $out"
else PASS=$((PASS + 1)); fi

out=$(run_hook '{"tool_name":"Edit","tool_input":{"file_path":"lib/foo.ts","old_string":"x","new_string":"try { doThing(); } catch (e) { logger.error(e); }"}}')
if is_denied "$out"; then
    FAIL=$((FAIL + 1))
    echo "FAIL: non-empty catch should ALLOW: $out"
else PASS=$((PASS + 1)); fi

out=$(run_hook '{"tool_name":"Edit","tool_input":{"file_path":"lib/foo.ex","old_string":"x","new_string":"rescue e in File.Error ->\n  reraise e, __STACKTRACE__\nend"}}')
if is_denied "$out"; then
    FAIL=$((FAIL + 1))
    echo "FAIL: narrow reraise rescue should ALLOW: $out"
else PASS=$((PASS + 1)); fi

out=$(run_hook '{"tool_name":"Edit","tool_input":{"file_path":"scripts/cleanup.sh","old_string":"x","new_string":"rm -f \"$TMP\" || true"}}')
if is_denied "$out"; then
    FAIL=$((FAIL + 1))
    echo "FAIL: || true should ALLOW (not mechanically gated): $out"
else PASS=$((PASS + 1)); fi

out=$(run_hook '{"tool_name":"Edit","tool_input":{"file_path":"lib/foo.ex","old_string":"x","new_string":"case v do\n  {:ok, r} -> r\n  _ -> nil\nend"}}')
if is_denied "$out"; then
    FAIL=$((FAIL + 1))
    echo "FAIL: catch-all _ -> nil should ALLOW (class-4 removed, over-fired on doc/string content): $out"
else PASS=$((PASS + 1)); fi

out=$(run_hook '{"tool_name":"Edit","tool_input":{"file_path":"lib/foo.ex","old_string":"x","new_string":"else\n  _ -> %{}\nend"}}')
if is_denied "$out"; then
    FAIL=$((FAIL + 1))
    echo "FAIL: else _ -> %{} should ALLOW (class-4 removed): $out"
else PASS=$((PASS + 1)); fi

out=$(run_hook '{"tool_name":"Bash","tool_input":{"command":"echo hi"}}')
if is_denied "$out"; then
    FAIL=$((FAIL + 1))
    echo "FAIL: non-content tool (Bash) should ALLOW: $out"
else PASS=$((PASS + 1)); fi

out=$(run_hook '{"tool_name":"Bash","tool_input":{"command":"printf '"'"'%s\\n'"'"' \"rescue _ -> :ok\" | codegen-log section developer-phoenix-backend --slug x"}}')
if is_denied "$out"; then
    FAIL=$((FAIL + 1))
    echo "FAIL: codegen-log write narrating a swallow phrase should ALLOW: $out"
else PASS=$((PASS + 1)); fi

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
