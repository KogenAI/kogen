#!/bin/bash
# subagent-read-discipline_test.sh — unit tests for subagent-read-discipline.sh

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
        stdout=$(printf '%s' "$input" | env $env_vars bash "$GUARD" 2>/dev/null || true)
    else
        stdout=$(printf '%s' "$input" | bash "$GUARD" 2>/dev/null || true)
    fi

    local outcome
    if printf '%s' "$stdout" | grep -q '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"'; then
        outcome="2"
    else
        outcome="0"
    fi

    if [ "$outcome" = "$expected" ]; then
        printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s — expected %s (deny=2/allow=0), got %s\n  stdout: %s\n' \
            "$desc" "$expected" "$outcome" "$stdout"
        fail=$((fail + 1))
    fi
}

# Helper: create a step log fixture with ## Plan (Files to touch) and ## Files Modified.
# NOTE: step log MUST be placed under a path matching codegen/logging/*.md so
# that session_log_from_transcript() can discover it (it filters on that pattern).
make_step_log() {
    local path="$1"
    local plan_files="${2:-}"
    local modified_files="${3:-}"
    mkdir -p "$(dirname "$path")"
    cat >"$path" <<EOF
# Step 1 — test

**Started**: 2026-05-20T00:00:00Z
**Gate**: make ci-fast

## Plan

**Goal**: test goal

**Files to touch**:
${plan_files}

## Slices

1. backend

## Files Modified

${modified_files}

## developer-phoenix-backend Section

(placeholder)
EOF
}

# Helper: create a fake transcript JSONL pointing at step log.
make_transcript() {
    local path="$1"
    local step_log_path="$2"
    printf '{"message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"%s"}}]}}\n' \
        "$step_log_path" >"$path"
}

# Helper: return a step log path that session_log_from_transcript() will discover.
# Creates <tmpdir>/codegen/logging/step.md and returns the path.
make_fixture_dir() {
    local tmp="$1"
    printf '%s/codegen/logging/step.md' "$tmp"
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
TMP_CWD10="$(mktemp -d)"
ABS_PC10="${TMP_CWD10}/PROJECT_CONTEXT.md"
F10='{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"'"$ABS_PC10"'"},"agent_id":"abc","agent_type":"developer-phoenix-backend","cwd":"'"$TMP_CWD10"'"}'
run_test "developer-phoenix-backend Read absolute PROJECT_CONTEXT.md denies" "2" "$F10"
rm -rf "$TMP_CWD10"

# ── Developer: context/*.md step-log allowlist ──────────────────────────────

# Test 11: developer Read context/builds.md — listed in ## Plan Files to touch → ALLOW
TMP11="$(mktemp -d)"
STEP11="$(make_fixture_dir "$TMP11")"
TRANS11="${TMP11}/transcript.jsonl"
make_step_log "$STEP11" "- context/builds.md (EDIT) — update section" ""
make_transcript "$TRANS11" "$STEP11"
F11='{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"context/builds.md"},"agent_id":"abc","agent_type":"developer-phoenix-backend","transcript_path":"'"$TRANS11"'"}'
run_test "developer Read context/builds.md listed in plan allows" "0" "$F11"
rm -rf "$TMP11"

# Test 12: developer Read context/builds.md — NOT listed in ## Plan → DENY
TMP12="$(mktemp -d)"
STEP12="$(make_fixture_dir "$TMP12")"
TRANS12="${TMP12}/transcript.jsonl"
make_step_log "$STEP12" "- lib/foo.ex (EXISTING) — some change" ""
make_transcript "$TRANS12" "$STEP12"
F12='{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"context/builds.md"},"agent_id":"abc","agent_type":"developer-phoenix-backend","transcript_path":"'"$TRANS12"'"}'
run_test "developer Read context/builds.md not in plan denies" "2" "$F12"
rm -rf "$TMP12"

# Test 13: developer Read lib/foo.ex → ALLOW (outside scope)
F13='{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"lib/foo.ex"},"agent_id":"abc","agent_type":"developer-phoenix-backend"}'
run_test "developer Read lib/foo.ex allows (outside scope)" "0" "$F13"

# Test 14: developer-phoenix-frontend Read context/builds.md NOT in plan → DENY
TMP14="$(mktemp -d)"
STEP14="$(make_fixture_dir "$TMP14")"
TRANS14="${TMP14}/transcript.jsonl"
make_step_log "$STEP14" "- lib/web/live/foo_live.ex (EXISTING) — render update" ""
make_transcript "$TRANS14" "$STEP14"
F14='{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"context/builds.md"},"agent_id":"abc","agent_type":"developer-phoenix-frontend","transcript_path":"'"$TRANS14"'"}'
run_test "developer-phoenix-frontend Read context/builds.md not in plan denies" "2" "$F14"
rm -rf "$TMP14"

# Test 15: developer-html Read PROJECT_CONTEXT.md → DENY (static stack coverage)
F15='{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"PROJECT_CONTEXT.md"},"agent_id":"abc","agent_type":"developer-html"}'
run_test "developer-html Read PROJECT_CONTEXT.md denies (static stack)" "2" "$F15"

# ── Developer: fail-open on missing transcript ──────────────────────────────

# Test 16: developer Read context/builds.md, empty TRANSCRIPT_PATH → ALLOW (fail-open)
F16='{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"context/builds.md"},"agent_id":"abc","agent_type":"developer-phoenix-backend","transcript_path":""}'
run_test "developer Read context/*.md with empty transcript_path allows (fail-open)" "0" "$F16"

# ── Reviewer: PROJECT_CONTEXT.md always denied ──────────────────────────────

# Test 17: reviewer-phoenix Read PROJECT_CONTEXT.md → DENY
F17='{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"PROJECT_CONTEXT.md"},"agent_id":"abc","agent_type":"reviewer-phoenix"}'
run_test "reviewer-phoenix Read PROJECT_CONTEXT.md denies" "2" "$F17"

# ── Reviewer: context/*.md ## Files Modified allowlist ───────────────────────

# Test 18: reviewer Read context/builds.md — listed in ## Files Modified → ALLOW
TMP18="$(mktemp -d)"
STEP18="$(make_fixture_dir "$TMP18")"
TRANS18="${TMP18}/transcript.jsonl"
make_step_log "$STEP18" "" "- context/builds.md"
make_transcript "$TRANS18" "$STEP18"
F18='{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"context/builds.md"},"agent_id":"abc","agent_type":"reviewer-phoenix","transcript_path":"'"$TRANS18"'"}'
run_test "reviewer Read context/builds.md in ## Files Modified allows" "0" "$F18"
rm -rf "$TMP18"

# Test 19: reviewer Read context/builds.md — NOT in ## Files Modified → DENY
TMP19="$(mktemp -d)"
STEP19="$(make_fixture_dir "$TMP19")"
TRANS19="${TMP19}/transcript.jsonl"
make_step_log "$STEP19" "" "- lib/foo.ex"
make_transcript "$TRANS19" "$STEP19"
F19='{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"context/builds.md"},"agent_id":"abc","agent_type":"reviewer-phoenix","transcript_path":"'"$TRANS19"'"}'
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

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
