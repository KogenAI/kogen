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
    jq -n \
        --arg agent_type "$agent_type" \
        --arg transcript_path "$transcript_path" \
        '{"hook_event_name":"SubagentStop","agent_type":$agent_type,"agent_id":"test","session_id":"testsession","transcript_path":$transcript_path,"cwd":""}'
}

# ── Test 1: Missing retrospective block → BLOCK ──────────────────────────────
T1=$(make_project)
LOG1="$T1/codegen/logging/step1_test.md"
cat >"$LOG1" <<'MD'
## developer-phoenix-backend Section

**Commands executed**: none

**Result**: Done.
MD
make_transcript "$T1/transcript.jsonl" "$LOG1"
out=$(make_input "developer-phoenix-backend" "$T1/transcript.jsonl" | bash "$HOOK" 2>/dev/null || true)
assert_block "missing retrospective block → block" "$out"
rm -rf "$T1"

# ── Test 2: Empty retrospective block → BLOCK ─────────────────────────────────
T2=$(make_project)
LOG2="$T2/codegen/logging/step1_test.md"
cat >"$LOG2" <<'MD'
## developer-phoenix-backend Section

**Result**: Done.

### What I Learned This Step

MD
make_transcript "$T2/transcript.jsonl" "$LOG2"
out=$(make_input "developer-phoenix-backend" "$T2/transcript.jsonl" | bash "$HOOK" 2>/dev/null || true)
assert_block "empty retrospective block → block" "$out"
rm -rf "$T2"

# ── Test 3: Minimal acceptable '- nothing notable' → ALLOW ───────────────────
T3=$(make_project)
LOG3="$T3/codegen/logging/step1_test.md"
cat >"$LOG3" <<'MD'
## developer-phoenix-backend Section

**Result**: Done.

### What I Learned This Step

- nothing notable
MD
make_transcript "$T3/transcript.jsonl" "$LOG3"
out=$(make_input "developer-phoenix-backend" "$T3/transcript.jsonl" | bash "$HOOK" 2>/dev/null || true)
assert_allow "minimal '- nothing notable' → allow" "$out"
rm -rf "$T3"

# ── Test 4: Local learning bullet → ALLOW ────────────────────────────────────
T4=$(make_project)
LOG4="$T4/codegen/logging/step1_test.md"
cat >"$LOG4" <<'MD'
## Plan

...content...

### What I Learned This Step

- [local] The context file needs updating when schema changes.
MD
make_transcript "$T4/transcript.jsonl" "$LOG4"
out=$(make_input "planner-phoenix" "$T4/transcript.jsonl" | bash "$HOOK" 2>/dev/null || true)
assert_allow "[local] bullet → allow" "$out"
rm -rf "$T4"

# ── Test 5: Shared learning bullet → ALLOW ───────────────────────────────────
T5=$(make_project)
LOG5="$T5/codegen/logging/step1_test.md"
cat >"$LOG5" <<'MD'
## reviewer-phoenix Section

**Result**: Done.

### What I Learned This Step

- [shared] Always check Credo before delegating to committer.
MD
make_transcript "$T5/transcript.jsonl" "$LOG5"
out=$(make_input "reviewer-phoenix" "$T5/transcript.jsonl" | bash "$HOOK" 2>/dev/null || true)
assert_allow "[shared] bullet → allow" "$out"
rm -rf "$T5"

# ── Test 6: Multiple bullets → ALLOW ─────────────────────────────────────────
T6=$(make_project)
LOG6="$T6/codegen/logging/step1_test.md"
cat >"$LOG6" <<'MD'
## developer-phoenix-frontend Section

**Result**: Done.

### What I Learned This Step

- [local] HEEx attrs must be alphabetical.
- [shared] Use Phoenix.Component.used_input?/1 for error display.
MD
make_transcript "$T6/transcript.jsonl" "$LOG6"
out=$(make_input "developer-phoenix-frontend" "$T6/transcript.jsonl" | bash "$HOOK" 2>/dev/null || true)
assert_allow "multiple bullets → allow" "$out"
rm -rf "$T6"

# ── Test 7: Non-matcher agent (committer) → ALLOW (pass-through) ─────────────
T7=$(make_project)
LOG7="$T7/codegen/logging/step1_test.md"
cat >"$LOG7" <<'MD'
## committer Section

**Result**: Committed.
MD
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
LOG9="$T9/codegen/logging/step1_test.md"
cat >"$LOG9" <<'MD'
## reviewer-phoenix Section

### What I Learned This Step

- nothing notable
MD
make_transcript "$T9/transcript.jsonl" "$LOG9"
# Ask about developer-phoenix-backend whose section is absent in this log.
out=$(make_input "developer-phoenix-backend" "$T9/transcript.jsonl" | bash "$HOOK" 2>/dev/null || true)
assert_allow "section header absent for agent → allow (defensive skip)" "$out"
rm -rf "$T9"

# ── Test 10: Retrospective with only whitespace lines → BLOCK ─────────────────
T10=$(make_project)
LOG10="$T10/codegen/logging/step1_test.md"
printf '## developer-phoenix-backend Section\n\n### What I Learned This Step\n\n   \n\t\n' >"$LOG10"
make_transcript "$T10/transcript.jsonl" "$LOG10"
out=$(make_input "developer-phoenix-backend" "$T10/transcript.jsonl" | bash "$HOOK" 2>/dev/null || true)
assert_block "only whitespace after retrospective header → block" "$out"
rm -rf "$T10"

# ── Test 11: planner-html with retrospective under ## Plan → ALLOW ────────────
T11=$(make_project)
LOG11="$T11/codegen/logging/step1_test.md"
cat >"$LOG11" <<'MD'
## Plan

Plan content for html stack.

### What I Learned This Step

- [local] HTML planner finding.
MD
make_transcript "$T11/transcript.jsonl" "$LOG11"
out=$(make_input "planner-html" "$T11/transcript.jsonl" | bash "$HOOK" 2>/dev/null || true)
assert_allow "planner-html with retrospective under ## Plan → allow" "$out"
rm -rf "$T11"

# ── Test 12: planner-phoenix with retrospective under ## Plan → ALLOW ─────────
T12=$(make_project)
LOG12="$T12/codegen/logging/step1_test.md"
cat >"$LOG12" <<'MD'
## Plan

Plan content for phoenix stack.

### What I Learned This Step

- nothing notable
MD
make_transcript "$T12/transcript.jsonl" "$LOG12"
out=$(make_input "planner-phoenix" "$T12/transcript.jsonl" | bash "$HOOK" 2>/dev/null || true)
assert_allow "planner-phoenix with retrospective under ## Plan → allow" "$out"
rm -rf "$T12"

# ── Test 13: planner-html missing retrospective under ## Plan → BLOCK ─────────
T13=$(make_project)
LOG13="$T13/codegen/logging/step1_test.md"
cat >"$LOG13" <<'MD'
## Plan

Plan content here, no retrospective.
MD
make_transcript "$T13/transcript.jsonl" "$LOG13"
out=$(make_input "planner-html" "$T13/transcript.jsonl" | bash "$HOOK" 2>/dev/null || true)
assert_block "planner-html missing retrospective under ## Plan → block" "$out"
rm -rf "$T13"

# ── Test 14: reviewer-phoenix with retrospective → ALLOW + REVIEWED stamp written ─
T14=$(make_project)
LOG14="$T14/codegen/logging/step1_test.md"
cat >"$LOG14" <<'MD'
## reviewer-phoenix Section

**Result**: QUALITY APPROVED ✅

### What I Learned This Step

- nothing notable
MD
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
LOG15="$T15/codegen/logging/step1_test.md"
cat >"$LOG15" <<'MD'
## developer-phoenix-backend Section

**Result**: Done.

### What I Learned This Step

- nothing notable
MD
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

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
