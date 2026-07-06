#!/usr/bin/env bash
# step-log-section-before-spawn_test.sh — unit tests for step-log-section-before-spawn.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/step-log-section-before-spawn.sh"

pass=0
fail=0

assert_deny() {
    local desc="$1"
    local stdout="$2"
    if printf '%s' "$stdout" | grep -q '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"'; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s — expected deny\n  stdout: %s\n' "$desc" "$stdout"
        fail=$((fail + 1))
    fi
}

assert_allow() {
    local desc="$1"
    local stdout="$2"
    if printf '%s' "$stdout" | grep -q '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"'; then
        printf 'FAIL: %s — expected allow, got deny\n  stdout: %s\n' "$desc" "$stdout"
        fail=$((fail + 1))
    else
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    fi
}

make_project() {
    local dir
    dir=$(mktemp -d)
    mkdir -p "$dir/codegen/logging"
    mkdir -p "$dir/codegen/pitches/ready"
    mkdir -p "$dir/codegen/pitches/shipped"
    printf '%s' "$dir"
}

make_transcript() {
    local transcript_path="$1"
    local log_path="$2"
    printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"%s"}}]}}\n' \
        "$log_path" >"$transcript_path"
}

mk_agent_input() {
    local stype="$1"
    local transcript_path="$2"
    # cwd defaults to the transcript's own tmpdir (its dirname) so
    # session_log_from_transcript()'s ${CWD:-$PWD}/codegen/logging/.active
    # lookup never falls through to the real repo $PWD's live sentinel —
    # isolates the test from whatever session happens to be running `make test`.
    local cwd
    cwd="$(dirname "${transcript_path:-}")"
    jq -n \
        --arg s "$stype" \
        --arg t "$transcript_path" \
        --arg c "$cwd" \
        '{"hook_event_name":"PreToolUse","tool_name":"Agent","tool_input":{"subagent_type":$s,"description":"x","prompt":"y"},"agent_id":"","agent_type":"","cwd":$c,"transcript_path":$t}'
}

mk_agent_input_with_cwd() {
    local stype="$1"
    local transcript_path="$2"
    local cwd="$3"
    jq -n \
        --arg s "$stype" \
        --arg t "$transcript_path" \
        --arg c "$cwd" \
        '{"hook_event_name":"PreToolUse","tool_name":"Agent","tool_input":{"subagent_type":$s,"description":"x","prompt":"y"},"agent_id":"","agent_type":"","cwd":$c,"transcript_path":$t}'
}

mk_non_agent_input() {
    local tool_name="$1"
    local transcript_path="$2"
    jq -n \
        --arg n "$tool_name" \
        --arg t "$transcript_path" \
        '{"hook_event_name":"PreToolUse","tool_name":$n,"tool_input":{"command":"ls"},"agent_id":"","agent_type":"","transcript_path":$t}'
}

# ── Test 1: deny when no step log in transcript ──────────────────────────────
T1=$(make_project)
# Transcript references no log file
FAKE_TRANSCRIPT="$T1/transcript.jsonl"
printf '' >"$FAKE_TRANSCRIPT"
out1=$(mk_agent_input "planner-phoenix" "$FAKE_TRANSCRIPT" | env -u CLAUDE_ROLE -u PI_ROLE CODEGEN_BUILD_NON_INTERACTIVE="" bash "$HOOK" 2>/dev/null || true)
assert_deny "deny: no step log in transcript (planner-phoenix)" "$out1"
rm -rf "$T1"

# ── Test 2: deny planner-phoenix when ## Plan header absent ─────────────────
T2=$(make_project)
LOG2="$T2/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_test_cycle.jsonl"
: >"$LOG2"
make_transcript "$T2/transcript.jsonl" "$LOG2"
out2=$(mk_agent_input "planner-phoenix" "$T2/transcript.jsonl" | env -u CLAUDE_ROLE -u PI_ROLE bash "$HOOK" 2>/dev/null || true)
assert_deny "deny: planner-phoenix — ## Plan header absent" "$out2"
rm -rf "$T2"

# ── Test 3: deny developer-phoenix-backend when its section header absent ────
T3=$(make_project)
LOG3="$T3/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_test_cycle.jsonl"
: >"$LOG3"
printf '%s\n' '{"ev": "role", "role": "planner-phoenix", "body": "planner wrote here"}' >>"$LOG3"
make_transcript "$T3/transcript.jsonl" "$LOG3"
out3=$(mk_agent_input "developer-phoenix-backend" "$T3/transcript.jsonl" | env -u CLAUDE_ROLE -u PI_ROLE bash "$HOOK" 2>/dev/null || true)
assert_deny "deny: developer-phoenix-backend — section header absent" "$out3"
rm -rf "$T3"

# ── Test 4: allow planner-phoenix when ## Plan header present (even empty) ───
T4=$(make_project)
LOG4="$T4/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_test_cycle.jsonl"
: >"$LOG4"
printf '%s\n' '{"ev": "role", "role": "planner-phoenix", "body": ""}' >>"$LOG4"
make_transcript "$T4/transcript.jsonl" "$LOG4"
out4=$(mk_agent_input "planner-phoenix" "$T4/transcript.jsonl" | env -u CLAUDE_ROLE -u PI_ROLE bash "$HOOK" 2>/dev/null || true)
assert_allow "allow: planner-phoenix — ## Plan header present (empty body)" "$out4"
rm -rf "$T4"

# ── Test 5: allow developer-phoenix-backend with header present ───────────────
T5=$(make_project)
LOG5="$T5/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_test_cycle.jsonl"
: >"$LOG5"
printf '%s\n' '{"ev": "role", "role": "planner-phoenix", "body": "planner wrote here"}' >>"$LOG5"
printf '%s\n' '{"ev": "role", "role": "developer-phoenix-backend", "body": ""}' >>"$LOG5"
make_transcript "$T5/transcript.jsonl" "$LOG5"
out5=$(mk_agent_input "developer-phoenix-backend" "$T5/transcript.jsonl" | env -u CLAUDE_ROLE -u PI_ROLE bash "$HOOK" 2>/dev/null || true)
assert_allow "allow: developer-phoenix-backend — section header present" "$out5"
rm -rf "$T5"

# ── Test 6: allow developer-phoenix-frontend with header present ──────────────
T6=$(make_project)
LOG6="$T6/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_test_cycle.jsonl"
: >"$LOG6"
printf '%s\n' '{"ev": "role", "role": "developer-phoenix-frontend", "body": ""}' >>"$LOG6"
make_transcript "$T6/transcript.jsonl" "$LOG6"
out6=$(mk_agent_input "developer-phoenix-frontend" "$T6/transcript.jsonl" | env -u CLAUDE_ROLE -u PI_ROLE bash "$HOOK" 2>/dev/null || true)
assert_allow "allow: developer-phoenix-frontend — section header present" "$out6"
rm -rf "$T6"

# ── Test 7: allow developer-static with header present ───────────────────────
T7=$(make_project)
LOG7="$T7/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_test_cycle.jsonl"
: >"$LOG7"
printf '%s\n' '{"ev": "role", "role": "developer-static", "body": ""}' >>"$LOG7"
make_transcript "$T7/transcript.jsonl" "$LOG7"
out7=$(mk_agent_input "developer-static" "$T7/transcript.jsonl" | env -u CLAUDE_ROLE -u PI_ROLE bash "$HOOK" 2>/dev/null || true)
assert_allow "allow: developer-static — section header present" "$out7"
rm -rf "$T7"

# ── Test 8: allow reviewer-phoenix with header present ───────────────────────
T8=$(make_project)
LOG8="$T8/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_test_cycle.jsonl"
: >"$LOG8"
printf '%s\n' '{"ev": "role", "role": "reviewer-phoenix", "body": ""}' >>"$LOG8"
make_transcript "$T8/transcript.jsonl" "$LOG8"
out8=$(mk_agent_input "reviewer-phoenix" "$T8/transcript.jsonl" | env -u CLAUDE_ROLE -u PI_ROLE bash "$HOOK" 2>/dev/null || true)
assert_allow "allow: reviewer-phoenix — section header present" "$out8"
rm -rf "$T8"

# ── Test 9: allow reviewer-static with header present ────────────────────────
T9=$(make_project)
LOG9="$T9/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_test_cycle.jsonl"
: >"$LOG9"
printf '%s\n' '{"ev": "role", "role": "reviewer-static", "body": ""}' >>"$LOG9"
make_transcript "$T9/transcript.jsonl" "$LOG9"
out9=$(mk_agent_input "reviewer-static" "$T9/transcript.jsonl" | env -u CLAUDE_ROLE -u PI_ROLE bash "$HOOK" 2>/dev/null || true)
assert_allow "allow: reviewer-static — section header present" "$out9"
rm -rf "$T9"

# ── Test 10: allow context-curator with header present ───────────────────────
T10=$(make_project)
LOG10="$T10/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_test_cycle.jsonl"
: >"$LOG10"
printf '%s\n' '{"ev": "role", "role": "context-curator", "body": ""}' >>"$LOG10"
make_transcript "$T10/transcript.jsonl" "$LOG10"
out10=$(mk_agent_input "context-curator" "$T10/transcript.jsonl" | env -u CLAUDE_ROLE -u PI_ROLE bash "$HOOK" 2>/dev/null || true)
assert_allow "allow: context-curator — section header present" "$out10"
rm -rf "$T10"

# ── Test 11: allow committer with header present ──────────────────────────────
T11=$(make_project)
LOG11="$T11/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_test_cycle.jsonl"
: >"$LOG11"
printf '%s\n' '{"ev": "role", "role": "committer", "body": ""}' >>"$LOG11"
make_transcript "$T11/transcript.jsonl" "$LOG11"
out11=$(mk_agent_input "committer" "$T11/transcript.jsonl" | env -u CLAUDE_ROLE -u PI_ROLE bash "$HOOK" 2>/dev/null || true)
assert_allow "allow: committer — section header present" "$out11"
rm -rf "$T11"

# ── Test 12: allow non-Agent tool (Bash) unconditionally ─────────────────────
T12=$(make_project)
# Empty transcript — no log. But tool is Bash, not Agent.
FAKE_TRANSCRIPT12="$T12/transcript.jsonl"
printf '' >"$FAKE_TRANSCRIPT12"
out12=$(mk_non_agent_input "Bash" "$FAKE_TRANSCRIPT12" | env -u CLAUDE_ROLE -u PI_ROLE bash "$HOOK" 2>/dev/null || true)
assert_allow "allow: non-Agent tool (Bash) — hook exits 0 unconditionally" "$out12"
rm -rf "$T12"

# ── Test 13: fail-open when transcript unreadable ────────────────────────────
T13=$(make_project)
# Pass a transcript path that does not exist.
out13=$(mk_agent_input "developer-phoenix-backend" "/nonexistent/transcript.jsonl" | env -u CLAUDE_ROLE -u PI_ROLE bash "$HOOK" 2>/dev/null || true)
assert_allow "allow: transcript unreadable — fail-open" "$out13"
rm -rf "$T13"

# ── Test 14: allow developer-static (unified static stack) ────────────────────
T14=$(make_project)
LOG14="$T14/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_test_cycle.jsonl"
: >"$LOG14"
printf '%s\n' '{"ev": "role", "role": "developer-static", "body": ""}' >>"$LOG14"
make_transcript "$T14/transcript.jsonl" "$LOG14"
out14=$(mk_agent_input "developer-static" "$T14/transcript.jsonl" | env -u CLAUDE_ROLE -u PI_ROLE bash "$HOOK" 2>/dev/null || true)
assert_allow "allow: developer-static (test 14) — section header present" "$out14"
rm -rf "$T14"

# ── Test 15: allow developer-static (unified static stack) ────────────────────
T15=$(make_project)
LOG15="$T15/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_test_cycle.jsonl"
: >"$LOG15"
printf '%s\n' '{"ev": "role", "role": "developer-static", "body": ""}' >>"$LOG15"
make_transcript "$T15/transcript.jsonl" "$LOG15"
out15=$(mk_agent_input "developer-static" "$T15/transcript.jsonl" | env -u CLAUDE_ROLE -u PI_ROLE bash "$HOOK" 2>/dev/null || true)
assert_allow "allow: developer-static (test 15) — section header present" "$out15"
rm -rf "$T15"

# ── Test 16: filesystem fallback when transcript lags (managed build) ────────
# Simulates a print-mode build where the transcript is flushed asynchronously:
# the transcript has NO Write entry for the current step log, but the file
# exists on disk with the required section header. OCG_APPS_ROOT is set and
# CWD is under it, so the filesystem fallback should find the log and allow.
T16_APPS=$(mktemp -d)
T16="$T16_APPS/myapp"
mkdir -p "$T16/codegen/logging"
LOG16="$T16/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_test_cycle.jsonl"
: >"$LOG16"
printf '%s\n' '{"ev": "role", "role": "planner-phoenix", "body": "planner wrote here"}' >>"$LOG16"
printf '%s\n' '{"ev": "role", "role": "developer-phoenix-backend", "body": ""}' >>"$LOG16"
# Transcript has only an unrelated older Write entry — simulating transcript lag
FAKE_TRANSCRIPT16="$T16/transcript.jsonl"
printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"codegen/logging/20240101_000000_old_cycle.jsonl"}}]}}\n' \
    >"$FAKE_TRANSCRIPT16"
export OCG_APPS_ROOT="$T16_APPS"
out16=$(mk_agent_input_with_cwd "developer-phoenix-backend" "$FAKE_TRANSCRIPT16" "$T16" | env -u CLAUDE_ROLE -u PI_ROLE bash "$HOOK" 2>/dev/null || true)
unset OCG_APPS_ROOT
assert_allow "allow: filesystem fallback when transcript lags in managed build" "$out16"
rm -rf "$T16_APPS"

# ── Test 17: no filesystem fallback outside managed build (no OCG_APPS_ROOT) ─
# Same setup as T16 (log on disk, transcript lags) but OCG_APPS_ROOT is unset.
# Should deny — strict transcript-bound resolution for interactive sessions.
T17=$(make_project)
LOG17="$T17/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_test_cycle.jsonl"
: >"$LOG17"
printf '%s\n' '{"ev": "role", "role": "developer-phoenix-backend", "body": ""}' >>"$LOG17"
FAKE_TRANSCRIPT17="$T17/transcript.jsonl"
printf '' >"$FAKE_TRANSCRIPT17"
out17=$(
    unset OCG_APPS_ROOT 2>/dev/null
    mk_agent_input "developer-phoenix-backend" "$FAKE_TRANSCRIPT17" | env -u CLAUDE_ROLE -u PI_ROLE -u CODEGEN_BUILD_NON_INTERACTIVE bash "$HOOK" 2>/dev/null || true
)
assert_deny "deny: no fallback outside managed build (OCG_APPS_ROOT unset)" "$out17"
rm -rf "$T17"

# ── Test 18: filesystem fallback finds log but section header absent ──────────
# Simulates a print-mode build (OCG_APPS_ROOT set, CWD under it) where the
# transcript is completely empty (no Write entries for any log file, i.e. full
# transcript lag). The filesystem fallback resolves the most-recent log on disk.
# That log exists but lacks the required section header.
# The hook should DENY with the "append header" message — NOT the "create log"
# message — confirming the fallback resolved the log before checking the header.
T18_APPS=$(mktemp -d)
T18="$T18_APPS/myapp"
mkdir -p "$T18/codegen/logging"
LOG18="$T18/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_test_cycle.jsonl"
: >"$LOG18"
printf '%s\n' '{"ev": "role", "role": "planner-phoenix", "body": "planner wrote here"}' >>"$LOG18"
# Transcript is empty — no Write entries at all — full transcript lag
FAKE_TRANSCRIPT18="$T18/transcript.jsonl"
printf '' >"$FAKE_TRANSCRIPT18"
export OCG_APPS_ROOT="$T18_APPS"
out18=$(mk_agent_input_with_cwd "developer-phoenix-backend" "$FAKE_TRANSCRIPT18" "$T18" | env -u CLAUDE_ROLE -u PI_ROLE bash "$HOOK" 2>/dev/null || true)
unset OCG_APPS_ROOT
assert_deny "deny: filesystem fallback finds log but role event absent — missing role (not create log)" "$out18"
# Verify the deny message names the missing role event (not the "create log" message)
if printf '%s' "$out18" | grep -q "missing 'developer-phoenix-backend' role event"; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: test 18 deny names the missing role event (correct message)\n'
    pass=$((pass + 1))
else
    printf 'FAIL: test 18 deny should mention the missing role event but got: %s\n' "$out18"
    fail=$((fail + 1))
fi
rm -rf "$T18_APPS"

# ── Test 19: allow shape role with no step log (investigative bypass) ─────────
T16=$(make_project)
FAKE_TRANSCRIPT16="$T16/transcript.jsonl"
printf '' >"$FAKE_TRANSCRIPT16"
out16=$(mk_agent_input "planner-phoenix" "$FAKE_TRANSCRIPT16" | CLAUDE_ROLE=shape bash "$HOOK" 2>/dev/null || true)
assert_allow "allow: CLAUDE_ROLE=shape — investigative bypass regardless of missing log" "$out16"
rm -rf "$T16"

# ── Test 20: allow debug role with no step log (investigative bypass) ─────────
T17=$(make_project)
FAKE_TRANSCRIPT17="$T17/transcript.jsonl"
printf '' >"$FAKE_TRANSCRIPT17"
out17=$(mk_agent_input "planner-phoenix" "$FAKE_TRANSCRIPT17" | CLAUDE_ROLE=debug bash "$HOOK" 2>/dev/null || true)
assert_allow "allow: CLAUDE_ROLE=debug — investigative bypass regardless of missing log" "$out17"
rm -rf "$T17"

# ── Test 21: allow ops role with no step log (investigative bypass) ───────────
T18=$(make_project)
FAKE_TRANSCRIPT18="$T18/transcript.jsonl"
printf '' >"$FAKE_TRANSCRIPT18"
out18=$(mk_agent_input "planner-phoenix" "$FAKE_TRANSCRIPT18" | CLAUDE_ROLE=ops bash "$HOOK" 2>/dev/null || true)
assert_allow "allow: CLAUDE_ROLE=ops — investigative bypass regardless of missing log" "$out18"
rm -rf "$T18"

# ── Test 22: deny unknown role with no step log (fail-closed) ─────────────────
T19=$(make_project)
FAKE_TRANSCRIPT19="$T19/transcript.jsonl"
printf '' >"$FAKE_TRANSCRIPT19"
out19=$(mk_agent_input "planner-phoenix" "$FAKE_TRANSCRIPT19" | CLAUDE_ROLE=banana bash "$HOOK" 2>/dev/null || true)
assert_deny "deny: CLAUDE_ROLE=banana — unknown role not bypassed, no log → deny" "$out19"
rm -rf "$T19"

# ── Test 22b: CLAUDE_ROLE=build denies with no step log (explicit build role) ─
T19B=$(make_project)
FAKE_TRANSCRIPT19B="$T19B/transcript.jsonl"
printf '' >"$FAKE_TRANSCRIPT19B"
out19b=$(mk_agent_input "planner-phoenix" "$FAKE_TRANSCRIPT19B" | CLAUDE_ROLE=build bash "$HOOK" 2>/dev/null || true)
assert_deny "deny: CLAUDE_ROLE=build — explicit build role enforces, no log → deny" "$out19b"
rm -rf "$T19B"

# ── Test 20 (bug fix): deny when log path in transcript but file never created ─
# Transcript has a Write entry for a logging path, but the file does NOT exist.
# This was the fail-open bug: ! -r is true on absent files → old code allowed.
T20=$(make_project)
FAKE_TRANSCRIPT20="$T20/transcript.jsonl"
GHOST_LOG="$T20/codegen/logging/20260101_000000_test-session_cycle.jsonl"
# Build transcript referencing the ghost log (file not created on disk).
printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"%s"}}]}}\n' \
    "$GHOST_LOG" >"$FAKE_TRANSCRIPT20"
out20=$(mk_agent_input "planner-phoenix" "$FAKE_TRANSCRIPT20" | env -u CLAUDE_ROLE -u PI_ROLE bash "$HOOK" 2>/dev/null || true)
assert_deny "deny: log path in transcript but file never created on disk" "$out20"
rm -rf "$T20"

# ── Test 21 (fail-open preserved): log exists but chmod 000 (unreadable) ───────
# Under root, chmod 000 is a no-op and the file remains readable. In that case
# the hook proceeds to check headers (deny for absent header). Either outcome
# (allow or deny) satisfies the invariant that the hook does NOT hard-deny on
# an existing-but-unreadable file. We assert: NOT a "file never created" deny.
T21=$(make_project)
LOG21="$T21/codegen/logging/20260101_000000_chmod-test_cycle.jsonl"
printf '# Step\n' >"$LOG21"
make_transcript "$T21/transcript.jsonl" "$LOG21"
chmod 000 "$LOG21"
out21=$(mk_agent_input "planner-phoenix" "$T21/transcript.jsonl" | env -u CLAUDE_ROLE -u PI_ROLE bash "$HOOK" 2>/dev/null || true)
# The file exists on disk — must NOT trigger the "never created" deny message.
if printf '%s' "$out21" | grep -q 'never created'; then
    printf 'FAIL: Test 21 — existing chmod-000 log triggered the "never created" deny (should be fail-open or header-absent deny)\n  stdout: %s\n' "$out21"
    fail=$((fail + 1))
else
    [ -n "${VERBOSE:-}" ] && printf 'PASS: fail-open preserved: chmod-000 log does not trigger never-created deny\n'
    pass=$((pass + 1))
fi
chmod 644 "$LOG21" 2>/dev/null || true
rm -rf "$T21"

# ── Forbidden-type skip guard tests (e–j) ─────────────────────────────────────

# Test 22e: build-mode (no CLAUDE_ROLE) + Plan, no step log → ALLOW (skip guard fires)
T22=$(make_project)
FAKE_TRANSCRIPT22="$T22/transcript.jsonl"
printf '' >"$FAKE_TRANSCRIPT22"
out22=$(mk_agent_input "Plan" "$FAKE_TRANSCRIPT22" | env -u CLAUDE_ROLE -u PI_ROLE bash "$HOOK" 2>/dev/null || true)
assert_allow "allow: build + Plan — skip guard defers to allowlist, no header demand" "$out22"
rm -rf "$T22"

# Test 22f: build-mode + empty subagent_type → ALLOW (skip guard fires)
T23=$(make_project)
FAKE_TRANSCRIPT23="$T23/transcript.jsonl"
printf '' >"$FAKE_TRANSCRIPT23"
out23=$(mk_agent_input "" "$FAKE_TRANSCRIPT23" | env -u CLAUDE_ROLE -u PI_ROLE bash "$HOOK" 2>/dev/null || true)
assert_allow "allow: build + empty subagent_type — skip guard defers to allowlist" "$out23"
rm -rf "$T23"

# Test 22g: build-mode + general-purpose → ALLOW (skip guard fires)
T24=$(make_project)
FAKE_TRANSCRIPT24="$T24/transcript.jsonl"
printf '' >"$FAKE_TRANSCRIPT24"
out24=$(mk_agent_input "general-purpose" "$FAKE_TRANSCRIPT24" | env -u CLAUDE_ROLE -u PI_ROLE bash "$HOOK" 2>/dev/null || true)
assert_allow "allow: build + general-purpose — skip guard defers to allowlist" "$out24"
rm -rf "$T24"

# Test 22h: build-mode + statusline-setup → ALLOW (skip guard fires)
T25=$(make_project)
FAKE_TRANSCRIPT25="$T25/transcript.jsonl"
printf '' >"$FAKE_TRANSCRIPT25"
out25=$(mk_agent_input "statusline-setup" "$FAKE_TRANSCRIPT25" | env -u CLAUDE_ROLE -u PI_ROLE bash "$HOOK" 2>/dev/null || true)
assert_allow "allow: build + statusline-setup — skip guard defers to allowlist" "$out25"
rm -rf "$T25"

# Test 22i: build-mode + Explore → ALLOW (skip guard fires — allowlist will deny)
T26=$(make_project)
FAKE_TRANSCRIPT26="$T26/transcript.jsonl"
printf '' >"$FAKE_TRANSCRIPT26"
out26=$(mk_agent_input "Explore" "$FAKE_TRANSCRIPT26" | env -u CLAUDE_ROLE -u PI_ROLE bash "$HOOK" 2>/dev/null || true)
assert_allow "allow: build + Explore — skip guard defers to allowlist" "$out26"
rm -rf "$T26"

# Test 22j: REGRESSION — build-mode + developer-phoenix-backend with log present but section header ABSENT
# Must still DENY (skip guard must NOT over-skip legal types)
T27=$(make_project)
LOG27="$T27/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_regression_cycle.jsonl"
: >"$LOG27"
printf '%s\n' '{"ev": "role", "role": "planner-phoenix", "body": "planner content only — no developer section header"}' >>"$LOG27"
make_transcript "$T27/transcript.jsonl" "$LOG27"
out27=$(mk_agent_input "developer-phoenix-backend" "$T27/transcript.jsonl" | env -u CLAUDE_ROLE -u PI_ROLE bash "$HOOK" 2>/dev/null || true)
assert_deny "deny: REGRESSION — build + developer-phoenix-backend, log present but section header absent" "$out27"
rm -rf "$T27"

# ── T28: prior stage (## Plan) present but body empty → DENY when spawning developer
# Scenario: planner subagent died; orchestrator skips ahead to spawn developer.
T28=$(make_project)
LOG28="$T28/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_empty-plan_cycle.jsonl"
: >"$LOG28"
printf '%s\n' '{"ev": "role", "role": "planner-phoenix", "body": ""}' >>"$LOG28"
printf '%s\n' '{"ev": "role", "role": "developer-phoenix-backend", "body": ""}' >>"$LOG28"
make_transcript "$T28/transcript.jsonl" "$LOG28"
out28=$(mk_agent_input "developer-phoenix-backend" "$T28/transcript.jsonl" | env -u CLAUDE_ROLE -u PI_ROLE bash "$HOOK" 2>/dev/null || true)
assert_deny "T28: deny — ## Plan present but empty, spawning developer blocked" "$out28"
# Verify the deny message mentions "body is empty"
if printf '%s' "$out28" | grep -q 'body is empty'; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: T28 deny message mentions body is empty\n'
    pass=$((pass + 1))
else
    printf 'FAIL: T28 deny message does not mention "body is empty"\n  stdout: %s\n' "$out28"
    fail=$((fail + 1))
fi
rm -rf "$T28"

# ── T29: ## Plan has only retrospective block → DENY when spawning developer ──
# Scenario: planner section body is only a retrospective stub — no real plan.
T29=$(make_project)
LOG29="$T29/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_plan-retro-only_cycle.jsonl"
: >"$LOG29"
printf '%s\n' '{"ev": "role", "role": "planner-phoenix", "body": "### What I Learned This Step\n\n- nothing notable"}' >>"$LOG29"
printf '%s\n' '{"ev": "role", "role": "developer-phoenix-backend", "body": ""}' >>"$LOG29"
make_transcript "$T29/transcript.jsonl" "$LOG29"
out29=$(mk_agent_input "developer-phoenix-backend" "$T29/transcript.jsonl" | env -u CLAUDE_ROLE -u PI_ROLE bash "$HOOK" 2>/dev/null || true)
assert_deny "T29: deny — ## Plan has only retrospective (no real plan content), developer spawn blocked" "$out29"
rm -rf "$T29"

# ── T30: prior stage has real content → ALLOW (regression guard) ─────────────
# Scenario: planner wrote real content in ## Plan; developer spawn allowed.
T30=$(make_project)
LOG30="$T30/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_real-plan_cycle.jsonl"
: >"$LOG30"
printf '%s\n' '{"ev": "role", "role": "planner-phoenix", "body": "Files to touch:\n- lib/foo.ex (NEW)\n- test/foo_test.exs (NEW)"}' >>"$LOG30"
printf '%s\n' '{"ev": "role", "role": "developer-phoenix-backend", "body": ""}' >>"$LOG30"
make_transcript "$T30/transcript.jsonl" "$LOG30"
out30=$(mk_agent_input "developer-phoenix-backend" "$T30/transcript.jsonl" | env -u CLAUDE_ROLE -u PI_ROLE bash "$HOOK" 2>/dev/null || true)
assert_allow "T30: allow — ## Plan has real content, developer spawn permitted" "$out30"
rm -rf "$T30"

# ── T31: codegen-log-only evidence (no Write event) → unconditional disk fallback
# Regression for the interactive/self-build deadlock: session-log-writer-only.sh
# hard-denies raw Write/Edit/MultiEdit on session logs, so codegen-log (a Bash
# tool_use) is the sole legal writer. The transcript here contains ONLY a
# codegen-log Bash invocation — no Write event — and neither OCG_APPS_ROOT nor
# CODEGEN_BUILD_NON_INTERACTIVE is set (interactive session). A real on-disk
# step log with both ## Plan (with body) and the developer section header
# (with body) must still resolve via the codegen-log-evidence disk fallback.
T31=$(make_project)
LOG31="$T31/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_codegen-log-only_cycle.jsonl"
: >"$LOG31"
printf '%s\n' '{"ev": "role", "role": "planner-phoenix", "body": "Files to touch:\n- lib/foo.ex (NEW)"}' >>"$LOG31"
printf '%s\n' '{"ev": "role", "role": "developer-phoenix-backend", "body": "dev wrote real content here"}' >>"$LOG31"
FAKE_TRANSCRIPT31="$T31/transcript.jsonl"
printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"codegen-log section --role developer-phoenix-backend --body @-"}}]}}\n' \
    >"$FAKE_TRANSCRIPT31"
out31=$(
    unset OCG_APPS_ROOT 2>/dev/null
    mk_agent_input_with_cwd "developer-phoenix-backend" "$FAKE_TRANSCRIPT31" "$T31" | env -u CLAUDE_ROLE -u PI_ROLE -u CODEGEN_BUILD_NON_INTERACTIVE bash "$HOOK" 2>/dev/null || true
)
assert_allow "T31: allow — codegen-log-only evidence resolves disk log unconditionally (no OCG_APPS_ROOT, no CODEGEN_BUILD_NON_INTERACTIVE)" "$out31"
rm -rf "$T31"

# ── T32: prior stage section body is ONLY an H3 verdict line (no bare prose) ──
# Scenario: reviewer-phoenix section body is exactly "### FINAL VERDICT —
# APPROVED" with no other prose. This is real content, not a retrospective
# stub — spawning context-curator must be ALLOWED. Regression guard for the
# awk fix that previously excluded ALL "###"-prefixed lines from the body
# scan, not just the "### What I Learned" retrospective block.
T32=$(make_project)
LOG32="$T32/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_verdict-only_cycle.jsonl"
: >"$LOG32"
printf '%s\n' '{"ev": "role", "role": "reviewer-phoenix", "body": "### FINAL VERDICT — APPROVED"}' >>"$LOG32"
printf '%s\n' '{"ev": "role", "role": "context-curator", "body": ""}' >>"$LOG32"
make_transcript "$T32/transcript.jsonl" "$LOG32"
out32=$(mk_agent_input "context-curator" "$T32/transcript.jsonl" | env -u CLAUDE_ROLE -u PI_ROLE bash "$HOOK" 2>/dev/null || true)
assert_allow "T32: allow — reviewer section body is only an H3 verdict line, context-curator spawn permitted" "$out32"
rm -rf "$T32"

# ── T33: ## Plan is retro-first then trailing prose → ALLOW (regression guard) ──
# Scenario: retrospective block appears BEFORE the trailing plan prose (not
# after). The extractor must bound the retro to its heading + blank/bullet
# lines only, so the trailing prose still counts as real plan content.
T33=$(make_project)
LOG33="$T33/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_plan-retro-first_cycle.jsonl"
: >"$LOG33"
printf '%s\n' '{"ev": "role", "role": "planner-phoenix", "body": "### What I Learned This Step\n\n- nothing notable\n\nThe real plan: implement feature X in lib/foo.ex."}' >>"$LOG33"
printf '%s\n' '{"ev": "role", "role": "developer-phoenix-backend", "body": ""}' >>"$LOG33"
make_transcript "$T33/transcript.jsonl" "$LOG33"
out33=$(mk_agent_input "developer-phoenix-backend" "$T33/transcript.jsonl" | env -u CLAUDE_ROLE -u PI_ROLE bash "$HOOK" 2>/dev/null || true)
assert_allow "T33: allow — ## Plan retro-first then trailing prose reads as real body, developer spawn permitted" "$out33"
rm -rf "$T33"

# ── Breadcrumb diagnostic tests (T34-T36) ─────────────────────────────────────

# T34: header-absent fire writes breadcrumb with expected fields; verdict unchanged
T34=$(make_project)
LOG34="$T34/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_test_cycle.jsonl"
: >"$LOG34"
printf '%s\n' '{"ev": "role", "role": "planner-phoenix", "body": "planner wrote here"}' >>"$LOG34"
make_transcript "$T34/transcript.jsonl" "$LOG34"
SID34="test-sid-34"
IN34=$(jq -n --arg s "developer-phoenix-backend" --arg t "$T34/transcript.jsonl" --arg c "$T34" --arg sid "$SID34" \
    '{"hook_event_name":"PreToolUse","tool_name":"Agent","tool_input":{"subagent_type":$s,"description":"x","prompt":"y"},"agent_id":"","agent_type":"","cwd":$c,"session_id":$sid,"transcript_path":$t}')
out34=$(printf '%s' "$IN34" | env -u CLAUDE_ROLE -u PI_ROLE bash "$HOOK" 2>/dev/null || true)
assert_deny "T34: header-absent fire — still deny" "$out34"
BC34="$T34/codegen/logging/.guard-diagnostics/${SID34}.jsonl"
if [ -f "$BC34" ] && jq -e '.need != "" and .grep_in_guard_log == "no" and (.guard == "step-log-section-before-spawn")' "$BC34" >/dev/null 2>&1; then
    echo "PASS: T34b breadcrumb written with expected fields"
    pass=$((pass + 1))
else
    echo "FAIL: T34b breadcrumb missing or malformed at $BC34"
    fail=$((fail + 1))
fi
rm -rf "$T34"

# T35: breadcrumb write FAILURE (diagnostics path occupied by a regular file)
# must NOT alter the verdict — still deny, no crash.
T35=$(make_project)
LOG35="$T35/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_test_cycle.jsonl"
: >"$LOG35"
printf '%s\n' '{"ev": "role", "role": "planner-phoenix", "body": "planner wrote here"}' >>"$LOG35"
make_transcript "$T35/transcript.jsonl" "$LOG35"
printf 'x' >"$T35/codegen/logging/.guard-diagnostics"
IN35=$(jq -n --arg s "developer-phoenix-backend" --arg t "$T35/transcript.jsonl" --arg c "$T35" \
    '{"hook_event_name":"PreToolUse","tool_name":"Agent","tool_input":{"subagent_type":$s,"description":"x","prompt":"y"},"agent_id":"","agent_type":"","cwd":$c,"transcript_path":$t}')
out35=$(printf '%s' "$IN35" | env -u CLAUDE_ROLE -u PI_ROLE bash "$HOOK" 2>/dev/null || true)
assert_deny "T35: verdict unchanged (still deny) when breadcrumb write fails" "$out35"
rm -rf "$T35"

# T36: deny texts no longer contain "Do not investigate"; point at breadcrumb path.
# Covers all 3 sites: no-log (91), never-created (97), header-absent (34 above).
T36=$(make_project)
FAKE_TRANSCRIPT36="$T36/transcript.jsonl"
printf '' >"$FAKE_TRANSCRIPT36"
out36_nolog=$(mk_agent_input "planner-phoenix" "$FAKE_TRANSCRIPT36" | env -u CLAUDE_ROLE -u PI_ROLE bash "$HOOK" 2>/dev/null || true)
if printf '%s' "$out36_nolog" | grep -q "Do not investigate"; then
    echo "FAIL: T36 no-log deny still contains 'Do not investigate'"
    fail=$((fail + 1))
else
    echo "PASS: T36 no-log deny no longer contains 'Do not investigate'"
    pass=$((pass + 1))
fi
if printf '%s' "$out36_nolog" | grep -q "guard-diagnostics"; then
    echo "PASS: T36b no-log deny points at breadcrumb path"
    pass=$((pass + 1))
else
    echo "FAIL: T36b no-log deny does not reference breadcrumb path"
    fail=$((fail + 1))
fi
rm -rf "$T36"

T36C=$(make_project)
GHOST_LOG36="$T36C/codegen/logging/20260101_000000_ghost-session_cycle.jsonl"
printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"%s"}}]}}\n' \
    "$GHOST_LOG36" >"$T36C/transcript.jsonl"
out36_ghost=$(mk_agent_input "planner-phoenix" "$T36C/transcript.jsonl" | env -u CLAUDE_ROLE -u PI_ROLE bash "$HOOK" 2>/dev/null || true)
if printf '%s' "$out36_ghost" | grep -q "Do not investigate"; then
    echo "FAIL: T36c never-created deny still contains 'Do not investigate'"
    fail=$((fail + 1))
else
    echo "PASS: T36c never-created deny no longer contains 'Do not investigate'"
    pass=$((pass + 1))
fi
if printf '%s' "$out36_ghost" | grep -q "guard-diagnostics"; then
    echo "PASS: T36d never-created deny points at breadcrumb path"
    pass=$((pass + 1))
else
    echo "FAIL: T36d never-created deny does not reference breadcrumb path"
    fail=$((fail + 1))
fi
rm -rf "$T36C"

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
