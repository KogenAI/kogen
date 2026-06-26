#!/bin/bash
# session-log-structure_test.sh — unit tests for session-log-structure.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/session-log-structure.sh"

pass=0
fail=0

TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

run_test() {
    local desc="$1"
    local expected="$2"
    local input="$3"
    local extra_env="${4:-}"

    local stdout
    if [ -n "$extra_env" ]; then
        stdout=$(printf '%s' "$input" | env $extra_env bash "$GUARD" 2>/dev/null || true)
    else
        stdout=$(printf '%s' "$input" | env -u CLAUDE_ROLE -u PI_ROLE bash "$GUARD" 2>/dev/null || true)
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

LOG_DIR="$TMP_DIR/codegen/logging"
mkdir -p "$LOG_DIR"

LOG_FILE="$LOG_DIR/20260101_120000_test_session.md"

# Helper: build a Write fixture. Args: file_path content
make_write_fixture() {
    local fp="$1" content="$2"
    jq -n --arg fp "$fp" --arg c "$content" \
        '{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":$fp,"content":$c},"agent_type":""}'
}

# Helper: build an Edit fixture. Args: file_path old_string new_string agent_type
make_edit_fixture() {
    local fp="$1" os="$2" ns="$3" at="$4"
    jq -n --arg fp "$fp" --arg os "$os" --arg ns "$ns" --arg at "$at" \
        '{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":$fp,"old_string":$os,"new_string":$ns},"agent_type":$at}'
}

# Helper: build a MultiEdit fixture. Args: file_path old_string new_string agent_type
make_multiedit_fixture() {
    local fp="$1" os="$2" ns="$3" at="$4"
    jq -n --arg fp "$fp" --arg os "$os" --arg ns "$ns" --arg at "$at" \
        '{"hook_event_name":"PreToolUse","tool_name":"MultiEdit","tool_input":{"file_path":$fp,"edits":[{"old_string":$os,"new_string":$ns}]},"agent_type":$at}'
}

# ── Test 1: Write new (non-existent) file, canonical order → ALLOW ──
rm -f "$LOG_FILE"
CONTENT=$(printf '# Step 1\n\n## Version Stamp\n\n- hash\n\n## Plan\n\nplan\n\n## Delegation Timeline\n\n| T | A |\n\n## Files Modified\n\nfoo\n\n## developer-phoenix-backend Section\n\nbody\n\n## reviewer-phoenix Section\n\nreview\n\n## committer Section\n\ncommit')
FIXTURE=$(make_write_fixture "$LOG_FILE" "$CONTENT")
run_test "Write new file, canonical order — ALLOW" "0" "$FIXTURE"

# ── Test 2: Write new file, out-of-order headers → DENY ──
rm -f "$LOG_FILE"
CONTENT=$(printf '# Step 1\n\n## Plan\n\nplan\n\n## committer Section\n\ncommit\n\n## developer-phoenix-backend Section\n\nbody')
FIXTURE=$(make_write_fixture "$LOG_FILE" "$CONTENT")
run_test "Write new file, out-of-order (committer before developer) — DENY" "2" "$FIXTURE"

# ── Test 3: Write to existing log dropping ## Plan → DENY ──
printf '# Step 1\n\n## Version Stamp\n\n- hash\n\n## Plan\n\nplan\n\n## Delegation Timeline\n\n| T | A |\n' >"$LOG_FILE"
CONTENT=$(printf '# Step 1\n\n## Version Stamp\n\n- hash\n\n## Delegation Timeline\n\n| T | A |\n')
FIXTURE=$(make_write_fixture "$LOG_FILE" "$CONTENT")
run_test "Write to existing log dropping ## Plan — DENY" "2" "$FIXTURE"

# ── Test 4: Write to existing log preserving all headers → ALLOW ──
printf '# Step 1\n\n## Plan\n\nplan\n\n## Delegation Timeline\n\n| T | A |\n' >"$LOG_FILE"
CONTENT=$(printf '# Step 1\n\n## Plan\n\nplan updated\n\n## Delegation Timeline\n\n| T | A | R |\n')
FIXTURE=$(make_write_fixture "$LOG_FILE" "$CONTENT")
run_test "Write to existing log preserving all headers — ALLOW" "0" "$FIXTURE"

# ── Test 5: Edit appending ## developer-phoenix-backend Section at EOF → ALLOW ──
printf '# Step 1\n\n## Plan\n\nplan\n\n## Files Modified\n\nfoo\n' >"$LOG_FILE"
NS=$(printf '\n## developer-phoenix-backend Section\n\nbody')
FIXTURE=$(make_edit_fixture "$LOG_FILE" "" "$NS" "developer-phoenix-backend")
run_test "Edit appending developer Section at EOF — ALLOW" "0" "$FIXTURE"

# ── Test 6: Edit whose old_string contains ## Plan, new_string omits it → DENY ──
printf '# Step 1\n\n## Plan\n\nplan\n' >"$LOG_FILE"
OS=$(printf '## Plan\n\nplan')
NS=$(printf 'no header here')
FIXTURE=$(make_edit_fixture "$LOG_FILE" "$OS" "$NS" "developer-phoenix-backend")
run_test "Edit removes ## Plan from old_string without restoring in new_string — DENY" "2" "$FIXTURE"

# ── Test 7: Edit whose old_string contains ## Plan, new_string re-includes it → ALLOW ──
printf '# Step 1\n\n## Plan\n\nplan\n' >"$LOG_FILE"
OS=$(printf '## Plan\n\nplan')
NS=$(printf '## Plan\n\nupdated plan')
FIXTURE=$(make_edit_fixture "$LOG_FILE" "$OS" "$NS" "developer-phoenix-backend")
run_test "Edit replaces ## Plan body, keeps ## Plan header — ALLOW" "0" "$FIXTURE"

# ── Test 8: Edit new_string with two headers wrong order (reviewer before developer) → DENY ──
printf '# Step 1\n\n## Plan\n\nplan\n\n## Files Modified\n\nfoo\n' >"$LOG_FILE"
NS=$(printf '\n## reviewer-phoenix Section\n\nreview\n\n## developer-phoenix-backend Section\n\nbody')
FIXTURE=$(make_edit_fixture "$LOG_FILE" "" "$NS" "orchestrator")
run_test "Edit appending reviewer before developer Section (wrong order) — DENY" "2" "$FIXTURE"

# ── Test 9: Edit appending ## reviewer-phoenix Section (pass 2) at EOF → ALLOW ──
printf '# Step 1\n\n## Plan\n\nplan\n\n## Files Modified\n\nfoo\n\n## developer-phoenix-backend Section\n\nbody\n\n## reviewer-phoenix Section\n\nreview\n' >"$LOG_FILE"
NS=$(printf '\n## reviewer-phoenix Section (pass 2)\n\npass2 review')
FIXTURE=$(make_edit_fixture "$LOG_FILE" "" "$NS" "reviewer-phoenix")
run_test "Edit appending reviewer Section (pass 2) at EOF — ALLOW" "0" "$FIXTURE"

# ── Test 10: Write with freeform unknown headers interleaved, recognized ones in order → ALLOW ──
rm -f "$LOG_FILE"
CONTENT=$(printf '# Step 1\n\n## Some Unknown Header\n\ndata\n\n## Plan\n\nplan\n\n## Another Freeform\n\nstuff\n\n## developer-phoenix-backend Section\n\nbody')
FIXTURE=$(make_write_fixture "$LOG_FILE" "$CONTENT")
run_test "Write with unknown headers interleaved, recognized in order — ALLOW" "0" "$FIXTURE"

# ── Test 11: CLAUDE_ROLE=debug, out-of-order Write → ALLOW (bypass) ──
rm -f "$LOG_FILE"
CONTENT=$(printf '# Step 1\n\n## committer Section\n\ncommit\n\n## developer-phoenix-backend Section\n\nbody')
FIXTURE=$(make_write_fixture "$LOG_FILE" "$CONTENT")
run_test "CLAUDE_ROLE=debug bypasses guard — ALLOW" "0" "$FIXTURE" "CLAUDE_ROLE=debug"

# ── Test 12: CLAUDE_ROLE=shape, header-removing Edit → ALLOW (bypass) ──
printf '# Step 1\n\n## Plan\n\nplan\n' >"$LOG_FILE"
OS=$(printf '## Plan\n\nplan')
NS=$(printf 'replaced without header')
FIXTURE=$(make_edit_fixture "$LOG_FILE" "$OS" "$NS" "orchestrator")
run_test "CLAUDE_ROLE=shape bypasses guard — ALLOW" "0" "$FIXTURE" "CLAUDE_ROLE=shape"

# ── Test 13: CLAUDE_ROLE=ops, header-removing Write → ALLOW (bypass) ──
printf '# Step 1\n\n## Plan\n\nplan\n' >"$LOG_FILE"
CONTENT=$(printf '# Step 1\n\nnew content no headers')
FIXTURE=$(make_write_fixture "$LOG_FILE" "$CONTENT")
run_test "CLAUDE_ROLE=ops bypasses guard — ALLOW" "0" "$FIXTURE" "CLAUDE_ROLE=ops"

# ── Test 14: Non-logging path (lib/foo.ex) → ALLOW (path gate) ──
OTHER_FILE="$TMP_DIR/lib/foo.ex"
mkdir -p "$(dirname "$OTHER_FILE")"
printf '# some elixir\n' >"$OTHER_FILE"
CONTENT=$(printf '## committer Section\n\n## developer-phoenix-backend Section\n')
FIXTURE=$(make_write_fixture "$OTHER_FILE" "$CONTENT")
run_test "Non-logging path — ALLOW (path gate)" "0" "$FIXTURE"

# ── Test 15: Bash tool → ALLOW (tool gate) ──
printf '# Step 1\n\n## Plan\n\nplan\n' >"$LOG_FILE"
FIXTURE=$(jq -n --arg fp "$LOG_FILE" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"echo hi"},"agent_type":""}')
run_test "Bash tool not guarded — ALLOW" "0" "$FIXTURE"

# ── Test 16: Edit on non-existent log → ALLOW (fail-open) ──
NONEXISTENT="$LOG_DIR/does-not-exist.md"
rm -f "$NONEXISTENT"
NS=$(printf '## committer Section\n\ncommit\n\n## developer-phoenix-backend Section\n\nbody')
FIXTURE=$(make_edit_fixture "$NONEXISTENT" "" "$NS" "developer-phoenix-backend")
run_test "Edit on non-existent log — ALLOW (fail-open)" "0" "$FIXTURE"

# ── Test 17: MultiEdit removing a header in one edit's old_string → DENY ──
printf '# Step 1\n\n## Plan\n\nplan\n\n## Delegation Timeline\n\n| T | A |\n' >"$LOG_FILE"
OS=$(printf '## Plan\n\nplan')
NS=$(printf 'body without plan header')
FIXTURE=$(make_multiedit_fixture "$LOG_FILE" "$OS" "$NS" "developer-phoenix-backend")
run_test "MultiEdit removing ## Plan in old_string — DENY" "2" "$FIXTURE"

# ── Test 18: Write to existing log, all headers preserved but reordered → DENY ──
printf '# Step 1\n\n## Plan\n\nplan\n\n## developer-phoenix-backend Section\n\nbody\n' >"$LOG_FILE"
CONTENT=$(printf '# Step 1\n\n## developer-phoenix-backend Section\n\nbody\n\n## Plan\n\nplan')
FIXTURE=$(make_write_fixture "$LOG_FILE" "$CONTENT")
run_test "Write to existing log, headers preserved but reordered (developer before Plan) — DENY" "2" "$FIXTURE"

# ── Test 19: In-place ## Plan edit with downstream sections on disk → ALLOW ──
# Regression: naive merge appended new_string after disk, causing ## Delegation Timeline
# on disk to appear after the re-stated ## Plan in new_string → false denial.
printf '## Plan\n\nold plan\n\n## Delegation Timeline\n\n| T | A |\n\n## Files Modified\n\nfoo\n' >"$LOG_FILE"
OS=$(printf '## Plan\n\nold plan')
NS=$(printf '## Plan\n\nupdated plan')
FIXTURE=$(make_edit_fixture "$LOG_FILE" "$OS" "$NS" "orchestrator")
run_test "In-place ## Plan edit with downstream sections on disk — ALLOW (naive-merge regression)" "0" "$FIXTURE"

# ── Test 20: Reviewer re-states ## reviewer-phoenix Section header at EOF → ALLOW ──
# Regression: naive merge appended new_string (with reviewer header) after disk content
# that already had reviewer header → false denial. Result-simulation replaces correctly.
printf '## Plan\n\nplan\n\n## Files Modified\n\nfoo\n\n## developer-phoenix-backend Section\n\nbody\n\n## reviewer-phoenix Section\n\n<placeholder>\n' >"$LOG_FILE"
OS=$(printf '## reviewer-phoenix Section\n\n<placeholder>')
NS=$(printf '## reviewer-phoenix Section\n\n**Verdict**: QUALITY APPROVED\n\nFindings.')
FIXTURE=$(make_edit_fixture "$LOG_FILE" "$OS" "$NS" "reviewer-phoenix")
run_test "Reviewer re-states section header when replacing placeholder — ALLOW (naive-merge regression)" "0" "$FIXTURE"

# ── Test 21: Born-malformed 1,3,4,5,1 disk + in-place ## Plan edit → DENY ──
# Regression for bash-3.2 planner DoS: the orchestrator's version-stamp EOF-append
# produced a log born with ## Version Stamp AFTER ## Files Modified (rank 1 after 5).
# A guard using ${var/$pat/repl} on a ##-leading old_string NO-OPs on bash 3.2 →
# simulated remains the malformed disk → check_order never fires → ALLOW (wrong).
# splice_first correctly replaces the ## Plan section → simulated still has trailing
# ## Version Stamp out-of-order → check_order fires → DENY (correct).
printf '## Version Stamp\n\n- hash\n\n## Plan\n\nold plan\n\n## Delegation Timeline\n\n| T | A |\n\n## Files Modified\n\nfoo\n\n## Version Stamp\n\n- harness: abc\n' >"$LOG_FILE"
OS=$(printf '## Plan\n\nold plan')
NS=$(printf '## Plan\n\nupdated plan')
FIXTURE=$(make_edit_fixture "$LOG_FILE" "$OS" "$NS" "orchestrator")
run_test "Born-malformed 1,3,4,5,1 disk + in-place ## Plan edit — DENY (bash-3.2 splice regression)" "2" "$FIXTURE"

# ── Test 22: ##-leading old_string → splice applied: out-of-order new_string → DENY ──
# Red/green differentiator for bash-3.2 ${var/$pat/repl} NO-OP bug.
# Disk is in-order. Edit's old_string begins with "## Plan" (##-leading).
# new_string contains only a developer section (rank 6) WITHOUT the Plan header —
# which would put a developer section in place of a Plan section, violating order.
# OLD code (bash 3.2): ${simulated/## Plan\n\nold plan/...} → SILENT NO-OP →
#   simulated = unchanged in-order disk → check_order ALLOW (wrong — missed violation).
# NEW code (splice_first): replaces correctly → simulated lacks ## Plan but has
#   ## developer section where Plan was, then ## Delegation Timeline → out-of-order
#   no — actually check_order only checks recognized headers; the new_string for
#   this test must inject an out-of-order violation detectable by check_order.
# Simpler: new_string INSERTS a ## committer Section (rank 10) BEFORE ## Plan (rank 3)
# by replacing the Plan body with committer + Plan restated at end.
# With splice: simulated = ... ## committer Section ... ## Plan ... ## Delegation ...
# → committer (10) before Plan (3) → check_order fires → DENY.
# Without splice (no-op): simulated = original in-order disk → check_order ALLOW (missed).
printf '## Version Stamp\n\n- hash\n\n## Plan\n\nold plan\n\n## Delegation Timeline\n\n| T | A |\n' >"$LOG_FILE"
OS=$(printf '## Plan\n\nold plan')
NS=$(printf '## committer Section\n\ncommit\n\n## Plan\n\nold plan')
FIXTURE=$(make_edit_fixture "$LOG_FILE" "$OS" "$NS" "orchestrator")
run_test "##-leading old_string applied: injected out-of-order committer before Plan — DENY (bash-3.2 regression)" "2" "$FIXTURE"

# ── Test 23: No-match edit (old_string absent from disk) → ALLOW, simulated == disk ──
# Regression for splice no-match duplication: an unguarded %% / # splice on a
# non-matching $old emits $var$new$var (doubles the disk). splice_first's
# containment guard returns $var unchanged → simulated == disk → ALLOW.
printf '## Version Stamp\n\n- hash\n\n## Plan\n\nsome plan\n\n## Delegation Timeline\n\n| T | A |\n' >"$LOG_FILE"
OS=$(printf '## Plan\n\nthis text is NOT in the file')
NS=$(printf '## Plan\n\nreplaced')
FIXTURE=$(make_edit_fixture "$LOG_FILE" "$OS" "$NS" "orchestrator")
run_test "No-match edit (old_string absent from disk) — ALLOW, simulated unchanged (no duplication)" "0" "$FIXTURE"

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
