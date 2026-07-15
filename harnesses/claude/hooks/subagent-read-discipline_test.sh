#!/bin/bash
# subagent-read-discipline_test.sh — unit tests for subagent-read-discipline.sh
#
# Note: run_test() strips CODEGEN_LOG_PATH from the guard's env — the
# hook's session_log_from_transcript() binds to that env var first (see
# session-log.md § Resolution precedence), and a developer session running
# these tests inherits its own real CODEGEN_LOG_PATH pin, which would
# otherwise hijack every isolated /var/tmp fixture in this file onto the
# real repo's live cycle log instead of the fixture under test.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/subagent-read-discipline.sh"

pass=0
fail=0

run_test() {
    local desc="$1"
    local expected="$2"
    local input="$3"
    local env_vars="${4:-}"

    local stdout
    if [ -n "$env_vars" ]; then
        stdout=$(printf '%s' "$input" | env -u CODEGEN_LOG_PATH $env_vars bash "$GUARD" 2>/dev/null || true)
    else
        stdout=$(printf '%s' "$input" | env -u CODEGEN_LOG_PATH bash "$GUARD" 2>/dev/null || true)
    fi

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

# Helper: create a real append-only JSONL cycle log fixture (schema:
# [0-9]{8}_[0-9]{6}_<slug>_cycle.jsonl — matches SESSION_LOG_NAME_RE in
# hooks-lib.sh) with one {"ev":"role",...} event whose body carries a
# ## Plan (Files to touch) block and a ## Files Modified block, so the
# hook's `jq -r 'select(.ev=="role" and .role==$r) | .body'` +
# awk-scan-for-heading logic under test actually exercises real JSONL
# parsing rather than a markdown fixture that session_log_from_transcript()
# can never discover (it only matches codegen/logging/*.jsonl).
make_step_log() {
    local path="$1"
    local role="$2"
    local plan_files="${3:-}"
    local modified_files="${4:-}"
    mkdir -p "$(dirname "$path")"

    local body
    body=$(
        cat <<EOF
# Step 1 — test

**Started**: 2026-05-20T00:00:00Z
**Gate**: make ci

## Plan

**Goal**: test goal

**Files to touch**:
${plan_files}

## Slices

1. backend

## Files Modified

${modified_files}
EOF
    )

    jq -n -c --arg role "$role" --arg body "$body" \
        '{"ev":"role","role":$role,"body":$body}' >"$path"
}

# Helper: create a fake transcript JSONL pointing at the cycle-log fixture.
make_transcript() {
    local path="$1"
    local step_log_path="$2"
    printf '{"message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"%s"}}]}}\n' \
        "$step_log_path" >"$path"
}

# Helper: return a cycle-log path that session_log_from_transcript() will
# discover via the transcript Write-event scan. Creates
# <tmpdir>/codegen/logging/<slug>_cycle.jsonl and returns the path.
# NOTE: caller MUST also pass a matching "cwd" in the hook's JSON input —
# otherwise CWD defaults to $PWD (the live repo) and session_log_from_transcript()
# falls through to the disk-mtime scan / .active sentinel of the REAL
# invoking session, silently discovering an unrelated real cycle log
# instead of this fixture (a vacuous-pass trap — see regression test below).
make_fixture_dir() {
    local tmp="$1"
    printf '%s/codegen/logging/20260101_000000_fixture_cycle.jsonl' "$tmp"
}

# ── Planner bypass ──────────────────────────────────────────────────────────

# Test 1: planner-phoenix Read PROJECT_CONTEXT.md → ALLOW
F1='{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"PROJECT_CONTEXT.md"},"agent_id":"abc","agent_type":"planner-phoenix"}'
run_test "planner-phoenix Read PROJECT_CONTEXT.md allows" "0" "$F1"

# Test 2: planner-phoenix Read context/builds.md → ALLOW
F2='{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"context/builds.md"},"agent_id":"abc","agent_type":"planner-phoenix"}'
run_test "planner-phoenix Read context/builds.md allows" "0" "$F2"

# ── Curator bypass ──────────────────────────────────────────────────────────

# Test 3: context-curator Read PROJECT_CONTEXT.md → ALLOW
F3='{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"PROJECT_CONTEXT.md"},"agent_id":"abc","agent_type":"context-curator"}'
run_test "context-curator Read PROJECT_CONTEXT.md allows" "0" "$F3"

# Test 4: context-curator Read context/builds.md → ALLOW
F4='{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"context/builds.md"},"agent_id":"abc","agent_type":"context-curator"}'
run_test "context-curator Read context/builds.md allows" "0" "$F4"

# ── Committer deny ──────────────────────────────────────────────────────────

# Test 5: committer Read PROJECT_CONTEXT.md → DENY
F5='{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"PROJECT_CONTEXT.md"},"agent_id":"abc","agent_type":"committer"}'
run_test "committer Read PROJECT_CONTEXT.md denies" "2" "$F5"

# Test 6: committer Read context/builds.md → DENY
F6='{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"context/builds.md"},"agent_id":"abc","agent_type":"committer"}'
run_test "committer Read context/builds.md denies" "2" "$F6"

# Test 7: committer Read lib/foo.ex → ALLOW (outside scope)
F7='{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"lib/foo.ex"},"agent_id":"abc","agent_type":"committer"}'
run_test "committer Read lib/foo.ex allows (outside scope)" "0" "$F7"

# ── Developer: PROJECT_CONTEXT.md always denied ─────────────────────────────

# Test 8: developer-phoenix-backend Read PROJECT_CONTEXT.md (relative) → DENY
F8='{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"PROJECT_CONTEXT.md"},"agent_id":"abc","agent_type":"developer-phoenix-backend"}'
run_test "developer-phoenix-backend Read PROJECT_CONTEXT.md denies" "2" "$F8"

# Test 9: developer-phoenix-backend Read codegen/PROJECT_CONTEXT.md (symlink form) → DENY
F9='{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"codegen/PROJECT_CONTEXT.md"},"agent_id":"abc","agent_type":"developer-phoenix-backend"}'
run_test "developer-phoenix-backend Read codegen/PROJECT_CONTEXT.md denies (symlink form)" "2" "$F9"

# Test 10: developer-phoenix-backend Read absolute PROJECT_CONTEXT.md → DENY
TMP_CWD10="$(mktemp -d /var/tmp/subagent-cwd-XXXXXX)"
ABS_PC10="${TMP_CWD10}/PROJECT_CONTEXT.md"
F10='{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"'"$ABS_PC10"'"},"agent_id":"abc","agent_type":"developer-phoenix-backend","cwd":"'"$TMP_CWD10"'"}'
run_test "developer-phoenix-backend Read absolute PROJECT_CONTEXT.md denies" "2" "$F10"
rm -rf "$TMP_CWD10"

# ── Developer: context/*.md step-log allowlist ──────────────────────────────

# Test 11: developer Read context/builds.md — listed in ## Plan Files to touch → ALLOW
TMP11="$(mktemp -d /var/tmp/subagent-read-XXXXXX)"
STEP11="$(make_fixture_dir "$TMP11")"
TRANS11="${TMP11}/transcript.jsonl"
make_step_log "$STEP11" "developer-phoenix-backend" "- context/builds.md (EDIT) — update section" ""
make_transcript "$TRANS11" "$STEP11"
F11='{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"context/builds.md"},"agent_id":"abc","agent_type":"developer-phoenix-backend","transcript_path":"'"$TRANS11"'","cwd":"'"$TMP11"'"}'
run_test "developer Read context/builds.md listed in plan allows" "0" "$F11"
rm -rf "$TMP11"

# Test 12: developer Read context/builds.md — NOT listed in ## Plan → DENY
# "cwd" is REQUIRED here (isolated tmpdir) — omitting it lets CWD default to
# $PWD (the live repo), which falls through session_log_from_transcript()'s
# .active-sentinel / disk-mtime-scan branches and discovers the REAL
# invoking session's cycle log instead of this fixture: a vacuous-pass trap
# (see "vacuous DENY" regression test below for the RED-then-GREEN proof).
TMP12="$(mktemp -d /var/tmp/subagent-read-XXXXXX)"
STEP12="$(make_fixture_dir "$TMP12")"
TRANS12="${TMP12}/transcript.jsonl"
make_step_log "$STEP12" "developer-phoenix-backend" "- lib/foo.ex (EXISTING) — some change" ""
make_transcript "$TRANS12" "$STEP12"
F12='{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"context/builds.md"},"agent_id":"abc","agent_type":"developer-phoenix-backend","transcript_path":"'"$TRANS12"'","cwd":"'"$TMP12"'"}'
run_test "developer Read context/builds.md not in plan denies" "2" "$F12"
rm -rf "$TMP12"

# Test 13: developer Read lib/foo.ex → ALLOW (outside scope)
F13='{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"lib/foo.ex"},"agent_id":"abc","agent_type":"developer-phoenix-backend"}'
run_test "developer Read lib/foo.ex allows (outside scope)" "0" "$F13"

# Test 14: developer-phoenix-frontend Read context/builds.md NOT in plan → DENY
TMP14="$(mktemp -d /var/tmp/subagent-read-XXXXXX)"
STEP14="$(make_fixture_dir "$TMP14")"
TRANS14="${TMP14}/transcript.jsonl"
make_step_log "$STEP14" "developer-phoenix-frontend" "- lib/web/live/foo_live.ex (EXISTING) — render update" ""
make_transcript "$TRANS14" "$STEP14"
F14='{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"context/builds.md"},"agent_id":"abc","agent_type":"developer-phoenix-frontend","transcript_path":"'"$TRANS14"'","cwd":"'"$TMP14"'"}'
run_test "developer-phoenix-frontend Read context/builds.md not in plan denies" "2" "$F14"
rm -rf "$TMP14"

# Test 15: developer-static Read PROJECT_CONTEXT.md → DENY (static stack coverage)
F15='{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"PROJECT_CONTEXT.md"},"agent_id":"abc","agent_type":"developer-static"}'
run_test "developer-static Read PROJECT_CONTEXT.md denies (static stack)" "2" "$F15"

# ── Developer: fail-open on missing transcript ──────────────────────────────

# Test 16: developer Read context/builds.md, empty TRANSCRIPT_PATH → ALLOW (fail-open)
TMP16="$(mktemp -d /var/tmp/subagent-read-XXXXXX)"
F16='{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"context/builds.md"},"agent_id":"abc","agent_type":"developer-phoenix-backend","transcript_path":"","cwd":"'"$TMP16"'"}'
run_test "developer Read context/*.md with empty transcript_path allows (fail-open)" "0" "$F16"
rm -rf "$TMP16"

# ── Reviewer: PROJECT_CONTEXT.md always denied ──────────────────────────────

# Test 17: reviewer-phoenix Read PROJECT_CONTEXT.md → DENY
F17='{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"PROJECT_CONTEXT.md"},"agent_id":"abc","agent_type":"reviewer-phoenix"}'
run_test "reviewer-phoenix Read PROJECT_CONTEXT.md denies" "2" "$F17"

# ── Reviewer: context/*.md ## Files Modified allowlist ───────────────────────

# Test 18: reviewer Read context/builds.md — listed in ## Files Modified → ALLOW
TMP18="$(mktemp -d /var/tmp/subagent-read-XXXXXX)"
STEP18="$(make_fixture_dir "$TMP18")"
TRANS18="${TMP18}/transcript.jsonl"
make_step_log "$STEP18" "reviewer-phoenix" "" "- context/builds.md"
make_transcript "$TRANS18" "$STEP18"
F18='{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"context/builds.md"},"agent_id":"abc","agent_type":"reviewer-phoenix","transcript_path":"'"$TRANS18"'","cwd":"'"$TMP18"'"}'
run_test "reviewer Read context/builds.md in ## Files Modified allows" "0" "$F18"
rm -rf "$TMP18"

# Test 19: reviewer Read context/builds.md — NOT in ## Files Modified → DENY
TMP19="$(mktemp -d /var/tmp/subagent-read-XXXXXX)"
STEP19="$(make_fixture_dir "$TMP19")"
TRANS19="${TMP19}/transcript.jsonl"
make_step_log "$STEP19" "reviewer-phoenix" "" "- lib/foo.ex"
make_transcript "$TRANS19" "$STEP19"
F19='{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"context/builds.md"},"agent_id":"abc","agent_type":"reviewer-phoenix","transcript_path":"'"$TRANS19"'","cwd":"'"$TMP19"'"}'
run_test "reviewer Read context/builds.md not in ## Files Modified denies" "2" "$F19"
rm -rf "$TMP19"

# Test 20: reviewer-static Read PROJECT_CONTEXT.md → DENY
F20='{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"PROJECT_CONTEXT.md"},"agent_id":"abc","agent_type":"reviewer-static"}'
run_test "reviewer-static Read PROJECT_CONTEXT.md denies" "2" "$F20"

# ── Orchestrator (empty AGENT_TYPE) — pass through ──────────────────────────

# Test 21: orchestrator (empty agent_type) Read PROJECT_CONTEXT.md → ALLOW (not our scope)
F21='{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"PROJECT_CONTEXT.md"},"agent_id":"","agent_type":""}'
run_test "orchestrator (empty agent_type) passes through (handled by other hook)" "0" "$F21"

# ── Non-Read tool — always pass through ──────────────────────────────────────

# Test 22: Write tool → ALLOW (out of matcher scope, defensive check)
F22='{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"context/builds.md"},"agent_id":"abc","agent_type":"developer-phoenix-backend"}'
run_test "non-Read tool (Write) allows regardless of path" "0" "$F22"

# ── Pitch deny (Move 1 — close pitch-read leak) ──────────────────────────────

# Test 23: developer-phoenix-backend Read codegen/pitches/foo.md → DENY
F23='{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"codegen/pitches/foo.md"},"agent_id":"abc","agent_type":"developer-phoenix-backend"}'
run_test "developer Read codegen/pitches/*.md denies" "2" "$F23"

# Test 24: reviewer-phoenix Read codegen/pitches/foo.md → DENY
F24='{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"codegen/pitches/foo.md"},"agent_id":"abc","agent_type":"reviewer-phoenix"}'
run_test "reviewer Read codegen/pitches/*.md denies" "2" "$F24"

# Test 25: committer Read codegen/pitches/foo.md → DENY
F25='{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"codegen/pitches/foo.md"},"agent_id":"abc","agent_type":"committer"}'
run_test "committer Read codegen/pitches/*.md denies" "2" "$F25"

# Test 26: planner-phoenix Read codegen/pitches/foo.md → ALLOW
F26='{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"codegen/pitches/foo.md"},"agent_id":"abc","agent_type":"planner-phoenix"}'
run_test "planner-phoenix Read codegen/pitches/*.md allows" "0" "$F26"

# ── Regression: DENY must be a genuine allowlist miss, not a vacuous ───────
# fail-through to the REAL invoking session's active cycle log. Proof: build
# a fixture where the "Files to touch" plan LISTS context/builds.md (so a
# genuine allowlist check must ALLOW), but omit "cwd" from the hook input so
# CWD defaults to $PWD. If the hook were silently discovering some unrelated
# real cycle log (via .active sentinel / disk-mtime fallback) instead of this
# fixture, it would DENY here (wrong) instead of ALLOW (correct) — the
# opposite of the vacuous-DENY failure mode this test targets, but the same
# root cause: cwd-less resolution leaking the real session's log into a
# fixture-driven test. Confirms cwd is load-bearing, not decorative.

# Test 27: developer Read context/builds.md, listed in plan, NO "cwd" in
# input → the hook's own CWD-defaulting-to-$PWD behavior means this cannot
# be asserted deterministically across environments (a real repo cycle log
# may or may not list context/builds.md) — instead assert directly against
# an isolated fixture that PROVES discovery by requiring an exact-match
# tmpdir the real repo's PWD can never satisfy.
TMP27="$(mktemp -d /var/tmp/subagent-read-XXXXXX)"
STEP27="$(make_fixture_dir "$TMP27")"
TRANS27="${TMP27}/transcript.jsonl"
make_step_log "$STEP27" "developer-phoenix-backend" "- context/builds.md (EDIT) — update section" ""
make_transcript "$TRANS27" "$STEP27"
F27='{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"context/builds.md"},"agent_id":"abc","agent_type":"developer-phoenix-backend","transcript_path":"'"$TRANS27"'","cwd":"'"$TMP27"'"}'
out27=$(printf '%s' "$F27" | bash "$GUARD" 2>/dev/null || true)
if printf '%s' "$out27" | grep -q '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"'; then
    printf 'FAIL: fixture-driven ALLOW must resolve via the isolated cwd fixture, not fall through to an unrelated real log — got deny\n  stdout: %s\n' "$out27"
    fail=$((fail + 1))
else
    [ -n "${VERBOSE:-}" ] && printf 'PASS: fixture-driven allow resolves via isolated cwd fixture\n'
    pass=$((pass + 1))
fi
rm -rf "$TMP27"

# Test 28: same fixture dir, but query a DIFFERENT AGENT_TYPE role than the
# one written into the fixture's JSONL "role" field (fixture has
# developer-phoenix-backend; query as developer-phoenix-frontend). The
# hook's jq select on .role==$AGENT_TYPE must find NO matching event for the
# queried role, so role_body/plan_block are empty and the path is NOT
# allowlisted → genuine DENY, not a same-role vacuous match.
TMP28="$(mktemp -d /var/tmp/subagent-read-XXXXXX)"
STEP28="$(make_fixture_dir "$TMP28")"
TRANS28="${TMP28}/transcript.jsonl"
make_step_log "$STEP28" "developer-phoenix-backend" "- context/builds.md (EDIT) — update section" ""
make_transcript "$TRANS28" "$STEP28"
F28='{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"context/builds.md"},"agent_id":"abc","agent_type":"developer-phoenix-frontend","transcript_path":"'"$TRANS28"'","cwd":"'"$TMP28"'"}'
run_test "developer-phoenix-frontend query against a backend-role fixture denies (no cross-role leak)" "2" "$F28"
rm -rf "$TMP28"

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
