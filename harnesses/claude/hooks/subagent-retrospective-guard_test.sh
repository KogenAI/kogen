#!/usr/bin/env bash
# subagent-retrospective-guard_test.sh — unit tests for subagent-retrospective-guard.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/subagent-retrospective-guard.sh"

pass=0
fail=0

assert_block() {
    local desc="$1"
    local out="$2"
    if printf '%s' "$out" | grep -q '"decision"[[:space:]]*:[[:space:]]*"block"'; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s — expected block, got: %s\n' "$desc" "$out"
        fail=$((fail + 1))
    fi
}

assert_allow() {
    local desc="$1"
    local out="$2"
    if printf '%s' "$out" | grep -q '"decision"'; then
        printf 'FAIL: %s — expected allow, got: %s\n' "$desc" "$out"
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
    printf '%s' "$dir"
}

# Write a transcript that records a Write to the given log path.
make_transcript() {
    local transcript_path="$1"
    local log_path="$2"
    printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"%s"}}]}}\n' \
        "$log_path" >"$transcript_path"
}

make_input() {
    local agent_type="$1"
    local transcript_path="${2:-}"
    # cwd defaults to the transcript's own tmpdir (its dirname) so this fixture's
    # session_log_from_transcript() call never falls through to the real repo
    # $PWD's codegen/logging/.active sentinel — isolates the test from whatever
    # live session happens to be running `make test`. Pass "" explicitly to
    # exercise the true empty-cwd fail-open/fallback path when needed.
    local cwd="${3-$(dirname "${transcript_path:-}")}"
    jq -n \
        --arg agent_type "$agent_type" \
        --arg transcript_path "$transcript_path" \
        --arg cwd "$cwd" \
        '{"hook_event_name":"SubagentStop","agent_type":$agent_type,"agent_id":"test","session_id":"testsession","transcript_path":$transcript_path,"cwd":$cwd}'
}

# ── Test 1: Missing retrospective block → BLOCK ──────────────────────────────
T1=$(make_project)
LOG1="$T1/codegen/logging/test_cycle.jsonl"
: >"$LOG1"
printf '%s\n' '{"ev": "role", "role": "developer-phoenix-backend", "body": "**Commands executed**: none\n\n**Result**: Done."}' >>"$LOG1"
make_transcript "$T1/transcript.jsonl" "$LOG1"
out=$(make_input "developer-phoenix-backend" "$T1/transcript.jsonl" | bash "$HOOK" 2>/dev/null || true)
assert_block "missing retrospective block → block" "$out"
rm -rf "$T1"

# ── Test 2: Empty retrospective block → BLOCK ─────────────────────────────────
T2=$(make_project)
LOG2="$T2/codegen/logging/test_cycle.jsonl"
: >"$LOG2"
printf '%s\n' '{"ev": "role", "role": "developer-phoenix-backend", "body": "**Result**: Done.\n\n### What I Learned This Step"}' >>"$LOG2"
make_transcript "$T2/transcript.jsonl" "$LOG2"
out=$(make_input "developer-phoenix-backend" "$T2/transcript.jsonl" | bash "$HOOK" 2>/dev/null || true)
assert_block "empty retrospective block → block" "$out"
rm -rf "$T2"

# ── Test 3: Minimal acceptable '- nothing notable' → ALLOW ───────────────────
T3=$(make_project)
LOG3="$T3/codegen/logging/test_cycle.jsonl"
: >"$LOG3"
printf '%s\n' '{"ev": "role", "role": "developer-phoenix-backend", "body": "**Result**: Done.\n\n### What I Learned This Step\n\n- nothing notable"}' >>"$LOG3"
make_transcript "$T3/transcript.jsonl" "$LOG3"
out=$(make_input "developer-phoenix-backend" "$T3/transcript.jsonl" | bash "$HOOK" 2>/dev/null || true)
assert_allow "minimal '- nothing notable' → allow" "$out"
rm -rf "$T3"

# ── Test 4: Local learning bullet → ALLOW ────────────────────────────────────
T4=$(make_project)
LOG4="$T4/codegen/logging/test_cycle.jsonl"
: >"$LOG4"
printf '%s\n' '{"ev": "role", "role": "planner-phoenix", "body": "...content...\n\n### What I Learned This Step\n\n- [local] The context file needs updating when schema changes."}' >>"$LOG4"
make_transcript "$T4/transcript.jsonl" "$LOG4"
out=$(make_input "planner-phoenix" "$T4/transcript.jsonl" | bash "$HOOK" 2>/dev/null || true)
assert_allow "[local] bullet → allow" "$out"
rm -rf "$T4"

# ── Test 5: Shared learning bullet → ALLOW ───────────────────────────────────
T5=$(make_project)
LOG5="$T5/codegen/logging/test_cycle.jsonl"
: >"$LOG5"
printf '%s\n' '{"ev": "role", "role": "reviewer-phoenix", "body": "**Result**: Done.\n\n### What I Learned This Step\n\n- [shared] Always check Credo before delegating to committer."}' >>"$LOG5"
make_transcript "$T5/transcript.jsonl" "$LOG5"
INPUT5=$(jq -n \
    --arg agent_type "reviewer-phoenix" \
    --arg transcript_path "$T5/transcript.jsonl" \
    --arg cwd "$T5" \
    '{"hook_event_name":"SubagentStop","agent_type":$agent_type,"agent_id":"test","session_id":"test5","transcript_path":$transcript_path,"cwd":$cwd}')
out=$(printf '%s' "$INPUT5" | bash "$HOOK" 2>/dev/null || true)
assert_allow "[shared] bullet → allow" "$out"
rm -rf "$T5"

# ── Test 6: Multiple bullets → ALLOW ─────────────────────────────────────────
T6=$(make_project)
LOG6="$T6/codegen/logging/test_cycle.jsonl"
: >"$LOG6"
printf '%s\n' '{"ev": "role", "role": "developer-phoenix-frontend", "body": "**Result**: Done.\n\n### What I Learned This Step\n\n- [local] HEEx attrs must be alphabetical.\n- [shared] Use Phoenix.Component.used_input?/1 for error display."}' >>"$LOG6"
make_transcript "$T6/transcript.jsonl" "$LOG6"
out=$(make_input "developer-phoenix-frontend" "$T6/transcript.jsonl" | bash "$HOOK" 2>/dev/null || true)
assert_allow "multiple bullets → allow" "$out"
rm -rf "$T6"

# ── Test 7: Non-matcher agent (committer) → ALLOW (pass-through) ─────────────
T7=$(make_project)
LOG7="$T7/codegen/logging/test_cycle.jsonl"
: >"$LOG7"
printf '%s\n' '{"ev": "role", "role": "committer", "body": "**Result**: Committed."}' >>"$LOG7"
make_transcript "$T7/transcript.jsonl" "$LOG7"
out=$(make_input "committer" "$T7/transcript.jsonl" | bash "$HOOK" 2>/dev/null || true)
assert_allow "non-matcher agent (committer) → allow (pass-through)" "$out"
rm -rf "$T7"

# ── Test 8: No log in transcript (defensive) → ALLOW ─────────────────────────
T8=$(make_project)
printf '' >"$T8/transcript.jsonl"
out=$(make_input "developer-phoenix-backend" "$T8/transcript.jsonl" | bash "$HOOK" 2>/dev/null || true)
assert_allow "no log in transcript → allow (defensive skip)" "$out"
rm -rf "$T8"

# ── Test 9: Section header absent (defensive) → ALLOW ────────────────────────
T9=$(make_project)
LOG9="$T9/codegen/logging/test_cycle.jsonl"
: >"$LOG9"
printf '%s\n' '{"ev": "role", "role": "reviewer-phoenix", "body": "### What I Learned This Step\n\n- nothing notable"}' >>"$LOG9"
make_transcript "$T9/transcript.jsonl" "$LOG9"
# Ask about developer-phoenix-backend whose section is absent in this log.
out=$(make_input "developer-phoenix-backend" "$T9/transcript.jsonl" | bash "$HOOK" 2>/dev/null || true)
assert_allow "section header absent for agent → allow (defensive skip)" "$out"
rm -rf "$T9"

# ── Test 10: Retrospective with only whitespace lines → BLOCK ─────────────────
T10=$(make_project)
LOG10="$T10/codegen/logging/test_cycle.jsonl"
jq -c -n '{ev: "role", role: "developer-phoenix-backend", body: "### What I Learned This Step\n\n   \n\t\n"}' >"$LOG10"
make_transcript "$T10/transcript.jsonl" "$LOG10"
out=$(make_input "developer-phoenix-backend" "$T10/transcript.jsonl" | bash "$HOOK" 2>/dev/null || true)
assert_block "only whitespace after retrospective header → block" "$out"
rm -rf "$T10"

# ── Test 11: planner-static with retrospective under ## Plan → ALLOW ────────────
T11=$(make_project)
LOG11="$T11/codegen/logging/test_cycle.jsonl"
: >"$LOG11"
printf '%s\n' '{"ev": "role", "role": "planner-phoenix", "body": "Plan content for html stack.\n\n### What I Learned This Step\n\n- [local] HTML planner finding."}' >>"$LOG11"
make_transcript "$T11/transcript.jsonl" "$LOG11"
out=$(make_input "planner-static" "$T11/transcript.jsonl" | bash "$HOOK" 2>/dev/null || true)
assert_allow "planner-static with retrospective under ## Plan → allow" "$out"
rm -rf "$T11"

# ── Test 12: planner-phoenix with retrospective under ## Plan → ALLOW ─────────
T12=$(make_project)
LOG12="$T12/codegen/logging/test_cycle.jsonl"
: >"$LOG12"
printf '%s\n' '{"ev": "role", "role": "planner-phoenix", "body": "Plan content for phoenix stack.\n\n### What I Learned This Step\n\n- nothing notable"}' >>"$LOG12"
make_transcript "$T12/transcript.jsonl" "$LOG12"
out=$(make_input "planner-phoenix" "$T12/transcript.jsonl" | bash "$HOOK" 2>/dev/null || true)
assert_allow "planner-phoenix with retrospective under ## Plan → allow" "$out"
rm -rf "$T12"

# ── Test 13: planner-static missing retrospective under ## Plan → BLOCK ─────────
T13=$(make_project)
LOG13="$T13/codegen/logging/test_cycle.jsonl"
: >"$LOG13"
printf '%s\n' '{"ev": "role", "role": "planner-phoenix", "body": "Plan content here, no retrospective."}' >>"$LOG13"
make_transcript "$T13/transcript.jsonl" "$LOG13"
out=$(make_input "planner-static" "$T13/transcript.jsonl" | bash "$HOOK" 2>/dev/null || true)
assert_block "planner-static missing retrospective under ## Plan → block" "$out"
rm -rf "$T13"

# ── Test 14: reviewer-phoenix with retrospective → ALLOW + REVIEWED stamp written ─
T14=$(make_project)
LOG14="$T14/codegen/logging/test_cycle.jsonl"
: >"$LOG14"
printf '%s\n' '{"ev": "role", "role": "reviewer-phoenix", "body": "**Result**: QUALITY APPROVED ✅\n\n### What I Learned This Step\n\n- nothing notable"}' >>"$LOG14"
make_transcript "$T14/transcript.jsonl" "$LOG14"
# Pass cwd so cycle-state.sh can find project_dir
INPUT14=$(jq -n \
    --arg agent_type "reviewer-phoenix" \
    --arg transcript_path "$T14/transcript.jsonl" \
    --arg cwd "$T14" \
    --arg session_id "test14" \
    '{"hook_event_name":"SubagentStop","agent_type":$agent_type,"agent_id":"test","session_id":$session_id,"transcript_path":$transcript_path,"cwd":$cwd}')
out=$(printf '%s' "$INPUT14" | bash "$HOOK" 2>/dev/null || true)
assert_allow "reviewer-phoenix with retrospective → allow" "$out"
cs_state=""
cs_file="$T14/codegen/gate-pending/cycle-state.json"
if [ -f "$cs_file" ]; then
    cs_state=$(jq -r '.state // ""' "$cs_file" 2>/dev/null || printf '')
fi
if [ "$cs_state" = "REVIEWED" ]; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: reviewer-phoenix stamps REVIEWED in cycle-state.json\n'
    pass=$((pass + 1))
else
    printf 'FAIL: reviewer-phoenix should stamp REVIEWED, got state=%s\n' "$cs_state"
    fail=$((fail + 1))
fi
rm -rf "$T14"

# ── Test 15: developer-phoenix-backend with retrospective → ALLOW + NO stamp ─
T15=$(make_project)
LOG15="$T15/codegen/logging/test_cycle.jsonl"
: >"$LOG15"
printf '%s\n' '{"ev": "role", "role": "developer-phoenix-backend", "body": "**Result**: Done.\n\n### What I Learned This Step\n\n- nothing notable"}' >>"$LOG15"
make_transcript "$T15/transcript.jsonl" "$LOG15"
INPUT15=$(jq -n \
    --arg agent_type "developer-phoenix-backend" \
    --arg transcript_path "$T15/transcript.jsonl" \
    --arg cwd "$T15" \
    --arg session_id "test15" \
    '{"hook_event_name":"SubagentStop","agent_type":$agent_type,"agent_id":"test","session_id":$session_id,"transcript_path":$transcript_path,"cwd":$cwd}')
out=$(printf '%s' "$INPUT15" | bash "$HOOK" 2>/dev/null || true)
assert_allow "developer-phoenix-backend with retrospective → allow (no stamp)" "$out"
cs_file15="$T15/codegen/gate-pending/cycle-state.json"
if [ ! -f "$cs_file15" ]; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: developer-phoenix-backend does NOT stamp cycle-state.json\n'
    pass=$((pass + 1))
else
    cs_state15=$(jq -r '.state // ""' "$cs_file15" 2>/dev/null || printf '')
    printf 'FAIL: developer should NOT stamp cycle-state, but state=%s was written\n' "$cs_state15"
    fail=$((fail + 1))
fi
rm -rf "$T15"

# ── Test 16: Two role events — event1 missing retro, event2 has retro → ALLOW ─
# JSONL is append-only: a re-spawned pass appends ANOTHER role event for the
# same role. The guard concatenates ALL role-event bodies for the agent and
# checks the combined text — there is no "last pass wins" concept (every
# event is equally valid); satisfying the retro requirement in ANY event body
# is sufficient.
T16=$(make_project)
LOG16="$T16/codegen/logging/test_cycle.jsonl"
: >"$LOG16"
printf '%s\n' '{"ev": "role", "role": "reviewer-phoenix", "body": "**Commands executed**: none\n\n**Result**: no retrospective in pass 1."}' >>"$LOG16"
printf '%s\n' '{"ev": "role", "role": "reviewer-phoenix", "body": "**Result**: Done.\n\n### What I Learned This Step\n\n- nothing notable\n\n## Files Modified\n\n- nothing"}' >>"$LOG16"
make_transcript "$T16/transcript.jsonl" "$LOG16"
INPUT16=$(jq -n \
    --arg agent_type "reviewer-phoenix" \
    --arg transcript_path "$T16/transcript.jsonl" \
    --arg cwd "$T16" \
    '{"hook_event_name":"SubagentStop","agent_type":$agent_type,"agent_id":"test","session_id":"test16","transcript_path":$transcript_path,"cwd":$cwd}')
out=$(printf '%s' "$INPUT16" | bash "$HOOK" 2>/dev/null || true)
assert_allow "two role events: event1 no retro, event2 has retro → concatenated body satisfies → allow" "$out"
rm -rf "$T16"

# ── Test 17: Two role events — event1 has retro, event2 missing retro → ALLOW ─
# Under JSONL's append-only, concatenate-all-events semantics, event1's retro
# text is STILL present in the concatenated body even though event2 (the most
# recent re-spawn pass) forgot to add one — there is no way to "invalidate" a
# prior event's content once it's on disk. This differs from the old markdown
# "last-block-wins" semantics (where a stale earlier block was structurally
# replaced/superseded); under JSONL, ALL prior content remains valid evidence.
T17=$(make_project)
LOG17="$T17/codegen/logging/test_cycle.jsonl"
: >"$LOG17"
printf '%s\n' '{"ev": "role", "role": "reviewer-phoenix", "body": "**Result**: Done.\n\n### What I Learned This Step\n\n- nothing notable"}' >>"$LOG17"
printf '%s\n' '{"ev": "role", "role": "reviewer-phoenix", "body": "**Result**: Done again, but forgot retrospective."}' >>"$LOG17"
make_transcript "$T17/transcript.jsonl" "$LOG17"
out=$(make_input "reviewer-phoenix" "$T17/transcript.jsonl" | bash "$HOOK" 2>/dev/null || true)
assert_allow "two role events: event1 has retro (still present in concatenated body) → allow" "$out"
rm -rf "$T17"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
