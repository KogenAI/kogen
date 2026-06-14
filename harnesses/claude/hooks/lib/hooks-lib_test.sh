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
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
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
    [ -n "${VERBOSE:-}" ] && printf 'PASS: debug_log silent without env\n'
fi

COMBOBULATE_HOOKS_DEBUG=1 debug_log hooks-lib-test-slug "with env: should log"
if grep -q "with env: should log" "$LOG" 2>/dev/null; then
    pass=$((pass + 1))
    [ -n "${VERBOSE:-}" ] && printf 'PASS: debug_log writes when COMBOBULATE_HOOKS_DEBUG set\n'
else
    fail=$((fail + 1))
    printf 'FAIL: debug_log did not write to %s\n' "$LOG"
fi
rm -f "$LOG"

# ── require_inspector_agent_type ─────────────────────────────────────────────

# unset AGENT_TYPE → exit 0 (allow, not inspector context)
exit_code=0
AGENT_TYPE="" bash -c "source '$SCRIPT_DIR/hooks-lib.sh' && require_inspector_agent_type && exit 1 || exit 0" || exit_code=$?
if [ "$exit_code" -eq 0 ]; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: require_inspector_agent_type exits 0 when AGENT_TYPE unset\n'
    pass=$((pass + 1))
else
    printf 'FAIL: require_inspector_agent_type did not exit 0 when AGENT_TYPE unset (exit %s)\n' "$exit_code"
    fail=$((fail + 1))
fi

# developer-phoenix-backend AGENT_TYPE → exit 0
exit_code=0
AGENT_TYPE="developer-phoenix-backend" bash -c "source '$SCRIPT_DIR/hooks-lib.sh' && require_inspector_agent_type && exit 1 || exit 0" || exit_code=$?
if [ "$exit_code" -eq 0 ]; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: require_inspector_agent_type exits 0 for developer-phoenix-backend\n'
    pass=$((pass + 1))
else
    printf 'FAIL: require_inspector_agent_type did not exit 0 for developer-phoenix-backend (exit %s)\n' "$exit_code"
    fail=$((fail + 1))
fi

# inspector AGENT_TYPE → returns (continue), so the subshell exits 0 via && exit 0
exit_code=0
AGENT_TYPE="inspector" bash -c "source '$SCRIPT_DIR/hooks-lib.sh' && require_inspector_agent_type && exit 0" || exit_code=$?
if [ "${exit_code:-0}" -eq 0 ]; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: require_inspector_agent_type returns (continues) for inspector\n'
    pass=$((pass + 1))
else
    printf 'FAIL: require_inspector_agent_type did not continue for inspector (exit %s)\n' "$exit_code"
    fail=$((fail + 1))
fi

# ── is_subagent ──────────────────────────────────────────────────────────────

result=$(AGENT_TYPE="developer-phoenix-backend" bash -c "source '$SCRIPT_DIR/hooks-lib.sh'; is_subagent && echo yes || echo no")
assert_eq "is_subagent true when AGENT_TYPE set" "yes" "$result"

result=$(AGENT_TYPE="" bash -c "source '$SCRIPT_DIR/hooks-lib.sh'; is_subagent && echo yes || echo no")
assert_eq "is_subagent false when AGENT_TYPE unset" "no" "$result"

# ── is_outer_session ─────────────────────────────────────────────────────────

result=$(AGENT_TYPE="" bash -c "source '$SCRIPT_DIR/hooks-lib.sh'; is_outer_session && echo yes || echo no")
assert_eq "is_outer_session true when AGENT_TYPE unset" "yes" "$result"

result=$(AGENT_TYPE="inspector" bash -c "source '$SCRIPT_DIR/hooks-lib.sh'; is_outer_session && echo yes || echo no")
assert_eq "is_outer_session false when AGENT_TYPE set" "no" "$result"

# ── session_log_from_transcript ──────────────────────────────────────────────

# Helper: build one JSONL line with a Write tool_use for the given path.
make_write_line() {
    local path="$1"
    printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"%s"}}]}}\n' "$path"
}

make_edit_line() {
    local path="$1"
    printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"%s"}}]}}\n' "$path"
}

# Case 1: A's log only → returns A's path.
TMP_T1=$(mktemp -d)
make_write_line "$TMP_T1/codegen/logging/A_session.md" >"$TMP_T1/transcript.jsonl"
result=$(TRANSCRIPT_PATH="$TMP_T1/transcript.jsonl" bash -c "source '$SCRIPT_DIR/hooks-lib.sh'; session_log_from_transcript")
assert_eq "session_log_from_transcript: A only → A path" "$TMP_T1/codegen/logging/A_session.md" "$result"
rm -rf "$TMP_T1"

# Case 2: B's log only → returns B's path.
TMP_T2=$(mktemp -d)
make_write_line "$TMP_T2/codegen/logging/B_session.md" >"$TMP_T2/transcript.jsonl"
result=$(TRANSCRIPT_PATH="$TMP_T2/transcript.jsonl" bash -c "source '$SCRIPT_DIR/hooks-lib.sh'; session_log_from_transcript")
assert_eq "session_log_from_transcript: B only → B path" "$TMP_T2/codegen/logging/B_session.md" "$result"
rm -rf "$TMP_T2"

# Case 3: Interleaved A+B writes → returns LAST (B).
TMP_T3=$(mktemp -d)
{
    make_write_line "$TMP_T3/codegen/logging/A_session.md"
    make_write_line "$TMP_T3/codegen/logging/B_session.md"
} >"$TMP_T3/transcript.jsonl"
result=$(TRANSCRIPT_PATH="$TMP_T3/transcript.jsonl" bash -c "source '$SCRIPT_DIR/hooks-lib.sh'; session_log_from_transcript")
assert_eq "session_log_from_transcript: interleaved A+B → last (B)" "$TMP_T3/codegen/logging/B_session.md" "$result"
rm -rf "$TMP_T3"

# Case 4: Zero tool_use writes to logging path → empty.
TMP_T4=$(mktemp -d)
printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"/tmp/other/not-logging.md"}}]}}\n' >"$TMP_T4/transcript.jsonl"
result=$(TRANSCRIPT_PATH="$TMP_T4/transcript.jsonl" bash -c "source '$SCRIPT_DIR/hooks-lib.sh'; session_log_from_transcript")
assert_eq "session_log_from_transcript: no logging writes → empty" "" "$result"
rm -rf "$TMP_T4"

# Case 5: TRANSCRIPT_PATH="" → empty.
result=$(TRANSCRIPT_PATH="" bash -c "source '$SCRIPT_DIR/hooks-lib.sh'; session_log_from_transcript")
assert_eq "session_log_from_transcript: empty TRANSCRIPT_PATH → empty" "" "$result"

# Case 6: TRANSCRIPT_PATH set to non-existent file → empty.
result=$(TRANSCRIPT_PATH="/tmp/no-such-transcript-$(date -u +%s).jsonl" bash -c "source '$SCRIPT_DIR/hooks-lib.sh'; session_log_from_transcript")
assert_eq "session_log_from_transcript: missing file → empty" "" "$result"

# Case 7: Edit tool_use also matched.
TMP_T7=$(mktemp -d)
make_edit_line "$TMP_T7/codegen/logging/edit_session.md" >"$TMP_T7/transcript.jsonl"
result=$(TRANSCRIPT_PATH="$TMP_T7/transcript.jsonl" bash -c "source '$SCRIPT_DIR/hooks-lib.sh'; session_log_from_transcript")
assert_eq "session_log_from_transcript: Edit tool_use matched" "$TMP_T7/codegen/logging/edit_session.md" "$result"
rm -rf "$TMP_T7"

# Case 8: Non-interactive fallback — CODEGEN_BUILD_NON_INTERACTIVE set, no
# apps-root, empty transcript, real log on disk → returns disk path by mtime.
TMP_T8=$(mktemp -d)
mkdir -p "$TMP_T8/codegen/logging"
: >"$TMP_T8/codegen/logging/20260611_000000_step1_demo.md"
: >"$TMP_T8/transcript.jsonl"
result=$(CODEGEN_BUILD_NON_INTERACTIVE=1 OCG_APPS_ROOT="" CWD="$TMP_T8" TRANSCRIPT_PATH="$TMP_T8/transcript.jsonl" \
    bash -c "source '$SCRIPT_DIR/hooks-lib.sh'; session_log_from_transcript")
assert_eq "session_log_from_transcript: non-interactive fallback → disk log" "$TMP_T8/codegen/logging/20260611_000000_step1_demo.md" "$result"
rm -rf "$TMP_T8"

# Case 9: Non-interactive fallback fail-closed — same env, empty logging dir
# (no .md files) → returns empty (gate denies, no phantom path).
TMP_T9=$(mktemp -d)
mkdir -p "$TMP_T9/codegen/logging"
: >"$TMP_T9/transcript.jsonl"
result=$(CODEGEN_BUILD_NON_INTERACTIVE=1 OCG_APPS_ROOT="" CWD="$TMP_T9" TRANSCRIPT_PATH="$TMP_T9/transcript.jsonl" \
    bash -c "source '$SCRIPT_DIR/hooks-lib.sh'; session_log_from_transcript")
assert_eq "session_log_from_transcript: non-interactive fallback empty dir → empty" "" "$result"
rm -rf "$TMP_T9"

# Case 10: TRANSCRIPT_PATH="" (empty string) with CODEGEN_BUILD_NON_INTERACTIVE set
# and a real log on disk → disk fallback fires, returns disk path.
TMP_T10=$(mktemp -d)
mkdir -p "$TMP_T10/codegen/logging"
: >"$TMP_T10/codegen/logging/20260614_000000_step1_demo.md"
result=$(CODEGEN_BUILD_NON_INTERACTIVE=1 OCG_APPS_ROOT="" CWD="$TMP_T10" TRANSCRIPT_PATH="" \
    bash -c "source '$SCRIPT_DIR/hooks-lib.sh'; session_log_from_transcript")
assert_eq "session_log_from_transcript: empty TRANSCRIPT_PATH + managed build → disk log" "$TMP_T10/codegen/logging/20260614_000000_step1_demo.md" "$result"
rm -rf "$TMP_T10"

# Case 11: TRANSCRIPT_PATH set to a nonexistent path with CODEGEN_BUILD_NON_INTERACTIVE set
# and a real log on disk → disk fallback fires, returns disk path.
TMP_T11=$(mktemp -d)
mkdir -p "$TMP_T11/codegen/logging"
: >"$TMP_T11/codegen/logging/20260614_000000_step1_demo.md"
result=$(CODEGEN_BUILD_NON_INTERACTIVE=1 OCG_APPS_ROOT="" CWD="$TMP_T11" TRANSCRIPT_PATH="/tmp/no-such-transcript-$(date -u +%s).jsonl" \
    bash -c "source '$SCRIPT_DIR/hooks-lib.sh'; session_log_from_transcript")
assert_eq "session_log_from_transcript: unreadable TRANSCRIPT_PATH + managed build → disk log" "$TMP_T11/codegen/logging/20260614_000000_step1_demo.md" "$result"
rm -rf "$TMP_T11"

echo ""
echo "Results: $pass passed, $fail failed"

[ "$fail" -gt 0 ] && exit 1
exit 0
