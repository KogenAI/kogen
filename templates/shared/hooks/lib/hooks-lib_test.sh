#!/bin/bash
# hooks-lib_test.sh — unit tests for hooks-lib.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=hooks-lib.sh
source "$SCRIPT_DIR/hooks-lib.sh"

pass=0
fail=0

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' "$desc" "$expected" "$actual"
        fail=$((fail + 1))
    fi
}

# ── parse_input — PreToolUse Edit fixture ────────────────────────────────────
INPUT_EDIT='{"tool_name":"Edit","agent_type":"developer-phoenix-backend","agent_id":"abc","tool_input":{"file_path":"lib/foo.ex","new_string":"defmodule Foo do\nend"},"cwd":"/tmp/proj"}'
{
    parse_input <<<"$INPUT_EDIT"
} <<<"$INPUT_EDIT"
# parse_input reads from stdin, but we already read RAW_INPUT inside; bash
# can't re-read once consumed. Use a here-string redirected to the function:
unset RAW_INPUT TOOL_NAME AGENT_TYPE AGENT_ID FILE_PATH CWD
RAW_INPUT="$INPUT_EDIT" # short-circuit: simulate parse_input's stdin read
# Re-run the per-field jq parsing manually via the same helpers:
TOOL_NAME=$(printf '%s' "$RAW_INPUT" | jq -r '.tool_name // ""')
AGENT_TYPE=$(printf '%s' "$RAW_INPUT" | jq -r '.agent_type // ""')
AGENT_ID=$(printf '%s' "$RAW_INPUT" | jq -r '.agent_id // ""')
FILE_PATH=$(printf '%s' "$RAW_INPUT" | jq -r '.tool_input.file_path // ""')
CWD=$(printf '%s' "$RAW_INPUT" | jq -r '.cwd // ""')

# Cleaner test: invoke parse_input via subshell with stdin pipe.
parse_in_subshell() {
    local input="$1"
    # shellcheck disable=SC2034  # vars are exported by parse_input
    printf '%s' "$input" | (
        parse_input
        printf 'TOOL=%s\nAGENT=%s\nFP=%s\nCWD=%s\n' "$TOOL_NAME" "$AGENT_TYPE" "$FILE_PATH" "$CWD"
    )
}

result=$(parse_in_subshell "$INPUT_EDIT")
assert_eq "parse_input TOOL_NAME" "TOOL=Edit" "$(printf '%s\n' "$result" | grep '^TOOL=')"
assert_eq "parse_input AGENT_TYPE" "AGENT=developer-phoenix-backend" "$(printf '%s\n' "$result" | grep '^AGENT=')"
assert_eq "parse_input FILE_PATH" "FP=lib/foo.ex" "$(printf '%s\n' "$result" | grep '^FP=')"
assert_eq "parse_input CWD" "CWD=/tmp/proj" "$(printf '%s\n' "$result" | grep '^CWD=')"

# ── parse_input — Write fixture (uses content, not new_string) ──────────────
INPUT_WRITE='{"tool_name":"Write","agent_type":"developer-phoenix-backend","tool_input":{"file_path":"lib/bar.ex","content":"defmodule Bar do\nend"}}'
result=$(printf '%s' "$INPUT_WRITE" | (
    parse_input
    printf '%s\n' "TOOL=$TOOL_NAME"
    printf '%s\n' "CONTENT=$(printf '%s' "$RAW_INPUT" | jq -r '.tool_input.content')"
))
assert_eq "parse_input Write TOOL_NAME" "TOOL=Write" "$(printf '%s\n' "$result" | grep '^TOOL=')"
expected_content="CONTENT=defmodule Bar do
end"
actual_content=$(printf '%s\n' "$result" | sed -n '/^CONTENT=/,$p')
assert_eq "parse_input Write content has multi-line" "$expected_content" "$actual_content"

# ── deny — emits the modern PreToolUse JSON envelope ─────────────────────────
denyout=$(deny "test reason")
assert_eq "deny permissionDecision" "deny" "$(printf '%s' "$denyout" | jq -r '.hookSpecificOutput.permissionDecision')"
assert_eq "deny hookEventName" "PreToolUse" "$(printf '%s' "$denyout" | jq -r '.hookSpecificOutput.hookEventName')"
assert_eq "deny reason" "test reason" "$(printf '%s' "$denyout" | jq -r '.hookSpecificOutput.permissionDecisionReason')"

# ── block — Stop event envelope ──────────────────────────────────────────────
blockout=$(block "stop reason")
assert_eq "block decision" "block" "$(printf '%s' "$blockout" | jq -r '.decision')"
assert_eq "block reason" "stop reason" "$(printf '%s' "$blockout" | jq -r '.reason')"

# ── hooks_realpath — existing path ───────────────────────────────────────────
assert_eq "hooks_realpath /tmp resolves macOS symlink" "/private/tmp" "$(hooks_realpath /tmp)"

# ── hooks_realpath — symlink target ──────────────────────────────────────────
LINK_DIR=$(mktemp -d)
ln -sf /etc "$LINK_DIR/etc-link"
assert_eq "hooks_realpath resolves symlink" "/private/etc" "$(hooks_realpath "$LINK_DIR/etc-link")"
rm -rf "$LINK_DIR"

# ── hooks_realpath — non-existent path ───────────────────────────────────────
assert_eq "hooks_realpath non-existent under /tmp" "/private/tmp/no/such/path" "$(hooks_realpath /tmp/no/such/path)"

# ── debug_log — gated by env vars ────────────────────────────────────────────
LOG=/tmp/hooks-lib-test-slug-debug.log
rm -f "$LOG"
debug_log hooks-lib-test-slug "without env: should NOT log"
if [ -e "$LOG" ]; then
    fail=$((fail + 1))
    printf 'FAIL: debug_log without env wrote to %s\n' "$LOG"
else
    pass=$((pass + 1))
    printf 'PASS: debug_log silent without env\n'
fi

COMBOBULATE_HOOKS_DEBUG=1 debug_log hooks-lib-test-slug "with env: should log"
if grep -q "with env: should log" "$LOG" 2>/dev/null; then
    pass=$((pass + 1))
    printf 'PASS: debug_log writes when COMBOBULATE_HOOKS_DEBUG set\n'
else
    fail=$((fail + 1))
    printf 'FAIL: debug_log did not write to %s\n' "$LOG"
fi
rm -f "$LOG"

echo ""
echo "Results: $pass passed, $fail failed"

[ "$fail" -gt 0 ] && exit 1
exit 0
