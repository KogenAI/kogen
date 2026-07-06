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

# ── parse_input — malformed/non-JSON stdin → hard exit 2 (fail-loud) ────────
# Non-JSON stdin is an anomaly (Claude Code always sends JSON) — parse_input
# must hard-fail rather than silently produce all-empty vars.
set +e
malformed_out=$(printf 'not valid json {{{' | (
    source "$SCRIPT_DIR/hooks-lib.sh"
    parse_input
) 2>&1)
malformed_rc=$?
set -e
assert_eq "parse_input malformed stdin: exit code 2" "2" "$malformed_rc"
if printf '%s' "$malformed_out" | grep -q "not valid JSON"; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "parse_input malformed stdin: stderr message present"
    pass=$((pass + 1))
else
    printf 'FAIL: parse_input malformed stdin: stderr message present\n  actual: %s\n' "$malformed_out"
    fail=$((fail + 1))
fi

# ── parse_input — valid JSON, absent optional field → "" (still tolerated) ──
# A field genuinely absent on a given event type (e.g. no tool_input.command
# on a Write event) must still default to "" — NOT hard-fail. This proves
# the jq-validity assert doesn't over-fire on legitimate optional-absence.
optional_out=$(printf '{"tool_name":"Write","tool_input":{"file_path":"lib/baz.ex"}}' | (
    source "$SCRIPT_DIR/hooks-lib.sh"
    parse_input
    printf 'CMD=[%s]\n' "$COMMAND"
))
assert_eq "parse_input optional-absent field: COMMAND defaults to empty" "CMD=[]" "$optional_out"

# ── parse_input — empty stdin → no exit 2 (tolerated) ────────────────────────
# Some hooks legitimately invoke parse_input with no stdin at all; the
# jq-validity assert must be guarded on non-empty RAW_INPUT so this stays
# tolerated (not a hard fail).
set +e
empty_out=$(printf '' | (
    source "$SCRIPT_DIR/hooks-lib.sh"
    parse_input
    printf 'TOOL=[%s]\n' "$TOOL_NAME"
) 2>&1)
empty_rc=$?
set -e
assert_eq "parse_input empty stdin: exit code 0 (tolerated)" "0" "$empty_rc"
assert_eq "parse_input empty stdin: TOOL_NAME defaults to empty" "TOOL=[]" "$empty_out"

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

CODEGEN_HOOKS_DEBUG=1 debug_log hooks-lib-test-slug "with env: should log"
if grep -q "with env: should log" "$LOG" 2>/dev/null; then
    pass=$((pass + 1))
    [ -n "${VERBOSE:-}" ] && printf 'PASS: debug_log writes when CODEGEN_HOOKS_DEBUG set\n'
else
    fail=$((fail + 1))
    printf 'FAIL: debug_log did not write to %s\n' "$LOG"
fi
rm -f "$LOG"

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
make_write_line "$TMP_T1/codegen/logging/A_cycle.jsonl" >"$TMP_T1/transcript.jsonl"
mkdir -p "$TMP_T1/codegen/logging" && : >"$TMP_T1/codegen/logging/A_cycle.jsonl"
result=$(TRANSCRIPT_PATH="$TMP_T1/transcript.jsonl" CWD="$TMP_T1" bash -c "source '$SCRIPT_DIR/hooks-lib.sh'; session_log_from_transcript")
assert_eq "session_log_from_transcript: A only → A path" "$TMP_T1/codegen/logging/A_cycle.jsonl" "$result"
rm -rf "$TMP_T1"

# Case 2: B's log only → returns B's path.
TMP_T2=$(mktemp -d)
make_write_line "$TMP_T2/codegen/logging/B_cycle.jsonl" >"$TMP_T2/transcript.jsonl"
mkdir -p "$TMP_T2/codegen/logging" && : >"$TMP_T2/codegen/logging/B_cycle.jsonl"
result=$(TRANSCRIPT_PATH="$TMP_T2/transcript.jsonl" CWD="$TMP_T2" bash -c "source '$SCRIPT_DIR/hooks-lib.sh'; session_log_from_transcript")
assert_eq "session_log_from_transcript: B only → B path" "$TMP_T2/codegen/logging/B_cycle.jsonl" "$result"
rm -rf "$TMP_T2"

# Case 3: Interleaved A+B writes → returns LAST (B).
TMP_T3=$(mktemp -d)
{
    make_write_line "$TMP_T3/codegen/logging/A_cycle.jsonl"
    make_write_line "$TMP_T3/codegen/logging/B_cycle.jsonl"
} >"$TMP_T3/transcript.jsonl"
mkdir -p "$TMP_T3/codegen/logging" && : >"$TMP_T3/codegen/logging/A_cycle.jsonl" && : >"$TMP_T3/codegen/logging/B_cycle.jsonl"
result=$(TRANSCRIPT_PATH="$TMP_T3/transcript.jsonl" CWD="$TMP_T3" bash -c "source '$SCRIPT_DIR/hooks-lib.sh'; session_log_from_transcript")
assert_eq "session_log_from_transcript: interleaved A+B → last (B)" "$TMP_T3/codegen/logging/B_cycle.jsonl" "$result"
rm -rf "$TMP_T3"

# Case 4: Zero tool_use writes to logging path → empty.
TMP_T4=$(mktemp -d)
printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"/tmp/other/not-logging.md"}}]}}\n' >"$TMP_T4/transcript.jsonl"
result=$(TRANSCRIPT_PATH="$TMP_T4/transcript.jsonl" CODEGEN_BUILD_NON_INTERACTIVE="" CWD="$TMP_T4" bash -c "source '$SCRIPT_DIR/hooks-lib.sh'; session_log_from_transcript")
assert_eq "session_log_from_transcript: no logging writes → empty" "" "$result"
rm -rf "$TMP_T4"

# Case 5: TRANSCRIPT_PATH="" → empty.
TMP_T5=$(mktemp -d)
result=$(TRANSCRIPT_PATH="" CODEGEN_BUILD_NON_INTERACTIVE="" CWD="$TMP_T5" bash -c "source '$SCRIPT_DIR/hooks-lib.sh'; session_log_from_transcript")
assert_eq "session_log_from_transcript: empty TRANSCRIPT_PATH → empty" "" "$result"
rm -rf "$TMP_T5"

# Case 6: TRANSCRIPT_PATH set to non-existent file → empty.
TMP_T6=$(mktemp -d)
result=$(TRANSCRIPT_PATH="/tmp/no-such-transcript-$(date -u +%s).jsonl" CODEGEN_BUILD_NON_INTERACTIVE="" CWD="$TMP_T6" bash -c "source '$SCRIPT_DIR/hooks-lib.sh'; session_log_from_transcript")
assert_eq "session_log_from_transcript: missing file → empty" "" "$result"
rm -rf "$TMP_T6"

# Case 7: Edit tool_use also matched.
TMP_T7=$(mktemp -d)
make_edit_line "$TMP_T7/codegen/logging/edit_cycle.jsonl" >"$TMP_T7/transcript.jsonl"
mkdir -p "$TMP_T7/codegen/logging" && : >"$TMP_T7/codegen/logging/edit_cycle.jsonl"
result=$(TRANSCRIPT_PATH="$TMP_T7/transcript.jsonl" CWD="$TMP_T7" bash -c "source '$SCRIPT_DIR/hooks-lib.sh'; session_log_from_transcript")
assert_eq "session_log_from_transcript: Edit tool_use matched" "$TMP_T7/codegen/logging/edit_cycle.jsonl" "$result"
rm -rf "$TMP_T7"

# Case 8: Non-interactive fallback — CODEGEN_BUILD_NON_INTERACTIVE set, no
# apps-root, empty transcript, real log on disk → returns disk path by mtime.
TMP_T8=$(mktemp -d)
mkdir -p "$TMP_T8/codegen/logging"
: >"$TMP_T8/codegen/logging/20260611_000000_demo_cycle.jsonl"
: >"$TMP_T8/transcript.jsonl"
result=$(CODEGEN_BUILD_NON_INTERACTIVE=1 OCG_APPS_ROOT="" CWD="$TMP_T8" TRANSCRIPT_PATH="$TMP_T8/transcript.jsonl" \
    bash -c "source '$SCRIPT_DIR/hooks-lib.sh'; session_log_from_transcript")
assert_eq "session_log_from_transcript: non-interactive fallback → disk log" "$TMP_T8/codegen/logging/20260611_000000_demo_cycle.jsonl" "$result"
rm -rf "$TMP_T8"

# Case 9: Non-interactive fallback fail-closed — same env, empty logging dir
# (no .jsonl files) → returns empty (gate denies, no phantom path).
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
: >"$TMP_T10/codegen/logging/20260614_000000_demo_cycle.jsonl"
result=$(CODEGEN_BUILD_NON_INTERACTIVE=1 OCG_APPS_ROOT="" CWD="$TMP_T10" TRANSCRIPT_PATH="" \
    bash -c "source '$SCRIPT_DIR/hooks-lib.sh'; session_log_from_transcript")
assert_eq "session_log_from_transcript: empty TRANSCRIPT_PATH + managed build → disk log" "$TMP_T10/codegen/logging/20260614_000000_demo_cycle.jsonl" "$result"
rm -rf "$TMP_T10"

# Case 11: TRANSCRIPT_PATH set to a nonexistent path with CODEGEN_BUILD_NON_INTERACTIVE set
# and a real log on disk → disk fallback fires, returns disk path.
TMP_T11=$(mktemp -d)
mkdir -p "$TMP_T11/codegen/logging"
: >"$TMP_T11/codegen/logging/20260614_000000_demo_cycle.jsonl"
result=$(CODEGEN_BUILD_NON_INTERACTIVE=1 OCG_APPS_ROOT="" CWD="$TMP_T11" TRANSCRIPT_PATH="/tmp/no-such-transcript-$(date -u +%s).jsonl" \
    bash -c "source '$SCRIPT_DIR/hooks-lib.sh'; session_log_from_transcript")
assert_eq "session_log_from_transcript: unreadable TRANSCRIPT_PATH + managed build → disk log" "$TMP_T11/codegen/logging/20260614_000000_demo_cycle.jsonl" "$result"
rm -rf "$TMP_T11"

# Helper: build one JSONL line with a Bash tool_use for the given command.
make_bash_line() {
    local cmd="$1"
    printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"%s"}}]}}\n' "$cmd"
}

# Case 12: codegen-log init (no Write event) + disk log present + neither
# OCG_APPS_ROOT nor CODEGEN_BUILD_NON_INTERACTIVE set → resolves disk log
# unconditionally. This is the interactive/self-build deadlock repro.
TMP_T12=$(mktemp -d)
mkdir -p "$TMP_T12/codegen/logging"
: >"$TMP_T12/codegen/logging/20260702_000000_demo_cycle.jsonl"
make_bash_line "codegen-log init --slug demo" >"$TMP_T12/transcript.jsonl"
result=$(TRANSCRIPT_PATH="$TMP_T12/transcript.jsonl" OCG_APPS_ROOT="" CODEGEN_BUILD_NON_INTERACTIVE="" CWD="$TMP_T12" \
    bash -c "source '$SCRIPT_DIR/hooks-lib.sh'; session_log_from_transcript")
assert_eq "session_log_from_transcript: codegen-log init evidence only → disk log" "$TMP_T12/codegen/logging/20260702_000000_demo_cycle.jsonl" "$result"
rm -rf "$TMP_T12"

# Case 13: codegen-log section --body @- (no Write event) → resolves disk log.
TMP_T13=$(mktemp -d)
mkdir -p "$TMP_T13/codegen/logging"
: >"$TMP_T13/codegen/logging/20260702_000000_demo_cycle.jsonl"
make_bash_line "codegen-log section --body @-" >"$TMP_T13/transcript.jsonl"
result=$(TRANSCRIPT_PATH="$TMP_T13/transcript.jsonl" OCG_APPS_ROOT="" CODEGEN_BUILD_NON_INTERACTIVE="" CWD="$TMP_T13" \
    bash -c "source '$SCRIPT_DIR/hooks-lib.sh'; session_log_from_transcript")
assert_eq "session_log_from_transcript: codegen-log section evidence only → disk log" "$TMP_T13/codegen/logging/20260702_000000_demo_cycle.jsonl" "$result"
rm -rf "$TMP_T13"

# Case 14: codegen-log append --role committer --body @- (no Write event) →
# resolves disk log.
TMP_T14=$(mktemp -d)
mkdir -p "$TMP_T14/codegen/logging"
: >"$TMP_T14/codegen/logging/20260702_000000_demo_cycle.jsonl"
make_bash_line "codegen-log append --role committer --body @-" >"$TMP_T14/transcript.jsonl"
result=$(TRANSCRIPT_PATH="$TMP_T14/transcript.jsonl" OCG_APPS_ROOT="" CODEGEN_BUILD_NON_INTERACTIVE="" CWD="$TMP_T14" \
    bash -c "source '$SCRIPT_DIR/hooks-lib.sh'; session_log_from_transcript")
assert_eq "session_log_from_transcript: codegen-log append evidence only → disk log" "$TMP_T14/codegen/logging/20260702_000000_demo_cycle.jsonl" "$result"
rm -rf "$TMP_T14"

# Case 15: non-writer Bash command only (e.g. ls codegen/logging/), no Write,
# empty env → empty. Evidence predicate must NOT over-match.
TMP_T15=$(mktemp -d)
mkdir -p "$TMP_T15/codegen/logging"
: >"$TMP_T15/codegen/logging/20260702_000000_demo_cycle.jsonl"
make_bash_line "ls codegen/logging/" >"$TMP_T15/transcript.jsonl"
result=$(TRANSCRIPT_PATH="$TMP_T15/transcript.jsonl" OCG_APPS_ROOT="" CODEGEN_BUILD_NON_INTERACTIVE="" CWD="$TMP_T15" \
    bash -c "source '$SCRIPT_DIR/hooks-lib.sh'; session_log_from_transcript")
assert_eq "session_log_from_transcript: non-writer bash command → empty" "" "$result"
rm -rf "$TMP_T15"

# Case 16: .active sentinel present and points at an existing log → resolved
# FIRST, before the transcript scan even runs (empty/no TRANSCRIPT_PATH).
TMP_T16=$(mktemp -d)
mkdir -p "$TMP_T16/codegen/logging"
: >"$TMP_T16/codegen/logging/20260703_000000_sentinel-demo_cycle.jsonl"
printf '%s' "$TMP_T16/codegen/logging/20260703_000000_sentinel-demo_cycle.jsonl" >"$TMP_T16/codegen/logging/.active"
result=$(TRANSCRIPT_PATH="" CWD="$TMP_T16" \
    bash -c "source '$SCRIPT_DIR/hooks-lib.sh'; session_log_from_transcript")
assert_eq "session_log_from_transcript: .active sentinel resolves with no transcript" "$TMP_T16/codegen/logging/20260703_000000_sentinel-demo_cycle.jsonl" "$result"
rm -rf "$TMP_T16"

# Case 17: .active sentinel takes precedence over a transcript scan that would
# otherwise resolve a DIFFERENT log.
TMP_T17=$(mktemp -d)
mkdir -p "$TMP_T17/codegen/logging"
: >"$TMP_T17/codegen/logging/20260703_000000_sentinel-demo_cycle.jsonl"
: >"$TMP_T17/codegen/logging/20260703_000001_transcript-demo_cycle.jsonl"
printf '%s' "$TMP_T17/codegen/logging/20260703_000000_sentinel-demo_cycle.jsonl" >"$TMP_T17/codegen/logging/.active"
make_write_line "$TMP_T17/codegen/logging/20260703_000001_transcript-demo_cycle.jsonl" >"$TMP_T17/transcript.jsonl"
result=$(TRANSCRIPT_PATH="$TMP_T17/transcript.jsonl" CWD="$TMP_T17" \
    bash -c "source '$SCRIPT_DIR/hooks-lib.sh'; session_log_from_transcript")
assert_eq "session_log_from_transcript: .active sentinel wins over transcript scan" "$TMP_T17/codegen/logging/20260703_000000_sentinel-demo_cycle.jsonl" "$result"
rm -rf "$TMP_T17"

# Case 18: stale .active sentinel (points at a deleted/relocated log) falls
# through to the transcript scan instead of returning a dead path.
TMP_T18=$(mktemp -d)
mkdir -p "$TMP_T18/codegen/logging"
: >"$TMP_T18/codegen/logging/20260703_000002_transcript-demo_cycle.jsonl"
printf '%s' "$TMP_T18/codegen/logging/20260703_000002_does-not-exist_cycle.jsonl" >"$TMP_T18/codegen/logging/.active"
make_write_line "$TMP_T18/codegen/logging/20260703_000002_transcript-demo_cycle.jsonl" >"$TMP_T18/transcript.jsonl"
result=$(TRANSCRIPT_PATH="$TMP_T18/transcript.jsonl" CWD="$TMP_T18" \
    bash -c "source '$SCRIPT_DIR/hooks-lib.sh'; session_log_from_transcript")
assert_eq "session_log_from_transcript: stale .active sentinel falls through to transcript scan" "$TMP_T18/codegen/logging/20260703_000002_transcript-demo_cycle.jsonl" "$result"
rm -rf "$TMP_T18"

# ── read_tool_failures ───────────────────────────────────────────────────────

# Case 1 (empty-state): no failures dir → "no tool failures recorded"
TMP_RF1=$(mktemp -d)
result=$(read_tool_failures "$TMP_RF1")
if printf '%s' "$result" | grep -q "no tool failures recorded"; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: read_tool_failures empty-state\n'
    pass=$((pass + 1))
else
    printf 'FAIL: read_tool_failures empty-state — got: %s\n' "$result"
    fail=$((fail + 1))
fi
rm -rf "$TMP_RF1"

# Case 2 (populated): two lines same tool + one other → groups with count 2
TMP_RF2=$(mktemp -d)
mkdir -p "$TMP_RF2/codegen/logging/failures"
printf '{"ts":"2026-06-01T10:00:00Z","tool":"Bash","error":"err1","agent":"a1"}\n' \
    >>"$TMP_RF2/codegen/logging/failures/sess1.jsonl"
printf '{"ts":"2026-06-01T10:01:00Z","tool":"Bash","error":"err2","agent":"a1"}\n' \
    >>"$TMP_RF2/codegen/logging/failures/sess1.jsonl"
printf '{"ts":"2026-06-01T10:02:00Z","tool":"Edit","error":"err3","agent":"a1"}\n' \
    >>"$TMP_RF2/codegen/logging/failures/sess1.jsonl"
result=$(read_tool_failures "$TMP_RF2")
if printf '%s' "$result" | grep -q "Bash" && printf '%s' "$result" | grep -q "2"; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: read_tool_failures groups Bash with count 2\n'
    pass=$((pass + 1))
else
    printf 'FAIL: read_tool_failures aggregation — got: %s\n' "$result"
    fail=$((fail + 1))
fi
rm -rf "$TMP_RF2"

# Case 3 (malformed-line): malformed line skipped, valid lines still aggregated
TMP_RF3=$(mktemp -d)
mkdir -p "$TMP_RF3/codegen/logging/failures"
printf '{"ts":"2026-06-01T11:00:00Z","tool":"Read","error":"nope","agent":"a2"}\n' \
    >>"$TMP_RF3/codegen/logging/failures/sess2.jsonl"
printf 'not valid json\n' \
    >>"$TMP_RF3/codegen/logging/failures/sess2.jsonl"
result=$(read_tool_failures "$TMP_RF3")
if printf '%s' "$result" | grep -q "Read"; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: read_tool_failures skips malformed line\n'
    pass=$((pass + 1))
else
    printf 'FAIL: read_tool_failures malformed-line — got: %s\n' "$result"
    fail=$((fail + 1))
fi
rm -rf "$TMP_RF3"

# ── read_gate_verdicts ───────────────────────────────────────────────────────

# Case 4 (empty-state): no file → "no gate verdicts recorded"
TMP_GV1=$(mktemp -d)
result=$(read_gate_verdicts "$TMP_GV1")
if printf '%s' "$result" | grep -q "no gate verdicts recorded"; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: read_gate_verdicts empty-state\n'
    pass=$((pass + 1))
else
    printf 'FAIL: read_gate_verdicts empty-state — got: %s\n' "$result"
    fail=$((fail + 1))
fi
rm -rf "$TMP_GV1"

# Case 5 (populated): failed ×2 + clear ×1 → verdict×count table shows failed 2
TMP_GV2=$(mktemp -d)
mkdir -p "$TMP_GV2/codegen/logging"
HIST_FILE_GV="$TMP_GV2/codegen/logging/gate-verdicts.jsonl"
printf '{"verdict":"failed","gate":"make test","ended":"2026-06-01T10:00:00Z"}\n' >>"$HIST_FILE_GV"
printf '{"verdict":"failed","gate":"make test","ended":"2026-06-01T10:01:00Z"}\n' >>"$HIST_FILE_GV"
printf '{"verdict":"clear","gate":"make test","ended":"2026-06-01T10:02:00Z"}\n' >>"$HIST_FILE_GV"
result=$(read_gate_verdicts "$TMP_GV2")
if printf '%s' "$result" | grep -q "failed" && printf '%s' "$result" | grep -q "2"; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: read_gate_verdicts shows failed count 2\n'
    pass=$((pass + 1))
else
    printf 'FAIL: read_gate_verdicts verdict×count — got: %s\n' "$result"
    fail=$((fail + 1))
fi
rm -rf "$TMP_GV2"

# ── SESSION_LOG_NAME_RE cross-site parity ────────────────────────────────────
# The canonical slug-class regex is hardcoded (kept in lockstep, not shared at
# runtime — bash guards / TS / YAML can't `source` a common fragment mid-grep-
# pattern) at 6 sites. Assert every site's literal regex string is byte-
# identical to hooks-lib.sh's SESSION_LOG_NAME_RE, so a future edit to one
# site without the others fails loud here instead of silently drifting.
CODEGEN_ROOT_PARITY="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

assert_regex_site_matches() {
    local desc="$1" file="$2" extract_pattern="$3"
    if [ ! -f "$file" ]; then
        printf 'FAIL: %s — file not found: %s\n' "$desc" "$file"
        fail=$((fail + 1))
        return
    fi
    local found
    found=$(grep -oE "$extract_pattern" "$file" | head -n 1)
    if [ "$found" = "$SESSION_LOG_NAME_RE" ]; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' "$desc" "$SESSION_LOG_NAME_RE" "${found:-<not found>}"
        fail=$((fail + 1))
    fi
}

# reviewer-guard.sh now references the shared $SESSION_LOG_NAME_RE variable
# (single-sourced from hooks-lib.sh) instead of carrying its own literal
# regex — assert the reference is present and it sources hooks-lib.sh, rather
# than re-extracting a literal string that no longer exists there.
reviewer_guard_file="$CODEGEN_ROOT_PARITY/harnesses/claude/hooks/reviewer-guard.sh"
if grep -qF 'source "$(dirname "$0")/lib/hooks-lib.sh"' "$reviewer_guard_file" &&
    grep -qF '${SESSION_LOG_NAME_RE}' "$reviewer_guard_file"; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: SESSION_LOG_NAME_RE parity: reviewer-guard.sh references the shared constant\n'
    pass=$((pass + 1))
else
    printf 'FAIL: SESSION_LOG_NAME_RE parity: reviewer-guard.sh does not source hooks-lib.sh + reference ${SESSION_LOG_NAME_RE}\n'
    fail=$((fail + 1))
fi

# The literal regex string (as it appears verbatim inside a single-quoted bash
# string or grep -E pattern) — escape nothing extra, grep -E extracts the
# exact substring between the sentinel markers used at each site.
RE_EXTRACT_PATTERN='\[0-9\]\{8\}_\[0-9\]\{6\}_\[a-z0-9_-\]\+_cycle\\\.jsonl\$'

assert_regex_site_matches "SESSION_LOG_NAME_RE parity: shared/rules/_core/session-log.md" \
    "$CODEGEN_ROOT_PARITY/shared/rules/_core/session-log.md" "$RE_EXTRACT_PATTERN"

# registry.yaml carries 2 match: lines (committer-write-allowlist,
# reviewer-guard-session-log-write) — both must match.
registry_file="$CODEGEN_ROOT_PARITY/shared/enforcement/registry.yaml"
registry_match_count=$(grep -cE "$RE_EXTRACT_PATTERN" "$registry_file" 2>/dev/null || true)
assert_eq "SESSION_LOG_NAME_RE parity: registry.yaml has 2 match: lines with the canonical regex" "2" "${registry_match_count:-0}"
registry_mismatch=$(grep -oE "$RE_EXTRACT_PATTERN" "$registry_file" | sort -u | wc -l | tr -d ' ')
assert_eq "SESSION_LOG_NAME_RE parity: registry.yaml's 2 match: lines are byte-identical" "1" "$registry_mismatch"
registry_extracted=$(grep -oE "$RE_EXTRACT_PATTERN" "$registry_file" | head -n 1)
assert_eq "SESSION_LOG_NAME_RE parity: registry.yaml regex matches hooks-lib.sh" "$SESSION_LOG_NAME_RE" "$registry_extracted"

# committer-write-allowlist.sh/.ts are compiler-GENERATED from registry.yaml's
# match: field (kind: generated, not kind: registration) — parity is already
# enforced transitively via the registry.yaml assertions above + make
# hook-parity (which fails if generated output drifts from the compiler's
# render of registry.yaml). Assert their generated output still carries the
# canonical string as a defense-in-depth check (catches a stale un-installed
# generated file even if registry.yaml itself is correct).
assert_regex_site_matches "SESSION_LOG_NAME_RE parity: committer-write-allowlist.sh (generated)" \
    "$CODEGEN_ROOT_PARITY/harnesses/claude/hooks/committer-write-allowlist.sh" "$RE_EXTRACT_PATTERN"
assert_regex_site_matches "SESSION_LOG_NAME_RE parity: committer-write-allowlist.ts (generated, Pi)" \
    "$CODEGEN_ROOT_PARITY/harnesses/pi/pi-extensions/enforcement/src/hooks/committer-write-allowlist.ts" "$RE_EXTRACT_PATTERN"

echo ""
echo "Results: $pass passed, $fail failed"

[ "$fail" -gt 0 ] && exit 1
exit 0
