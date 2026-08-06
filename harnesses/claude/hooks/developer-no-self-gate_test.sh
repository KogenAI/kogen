#!/bin/bash
# developer-no-self-gate_test.sh — unit tests for developer-no-self-gate.sh

set -u

# This file's default assertions target the legacy (non-loop) count-of-3 cap
# path. Unset any ambient CODEGEN_LOOP so an outer session running under the
# Elixir loop (CODEGEN_LOOP=1) cannot leak into these tests and silently
# divert them to the loop-mode progress-bounded branch. Loop-mode tests below
# opt back in explicitly per-call via `CODEGEN_LOOP=1 bash "$HOOK"`.
unset CODEGEN_LOOP

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/developer-no-self-gate.sh"

pass=0
fail=0

assert_contains() {
    local desc="$1"
    local needle="$2"
    local haystack="$3"
    if printf '%s' "$haystack" | grep -qF "$needle"; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s\n  needle: %s\n  haystack: %s\n' "$desc" "$needle" "$haystack"
        fail=$((fail + 1))
    fi
}

assert_not_contains() {
    local desc="$1"
    local needle="$2"
    local haystack="$3"
    if printf '%s' "$haystack" | grep -qF "$needle"; then
        printf 'FAIL: %s\n  unexpected: %s\n  haystack: %s\n' "$desc" "$needle" "$haystack"
        fail=$((fail + 1))
    else
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    fi
}

make_input() {
    local cmd="$1"
    local agent="${2:-developer-phoenix-backend}"
    local sid="${3:-test-session-$$}"
    jq -n \
        --arg cmd "$cmd" \
        --arg agent "$agent" \
        --arg sid "$sid" \
        '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":$cmd},"agent_type":$agent,"agent_id":"abc","session_id":$sid}'
}

# ── Test 1: non-developer agent → ALLOW ──────────────────────────────────────
SID1="sid1-$$-$(date -u +%s)"
rm -f "/tmp/codegen-self-gate-${SID1}.count"
out=$(make_input "mix test test/foo_test.exs" "reviewer-phoenix" "$SID1" | bash "$HOOK" 2>/dev/null || true)
assert_not_contains "non-developer ALLOWED" '"permissionDecision"' "$out"
rm -f "/tmp/codegen-self-gate-${SID1}.count"

# ── Test 2: non-CI command → ALLOW ───────────────────────────────────────────
SID2="sid2-$$-$(date -u +%s)"
rm -f "/tmp/codegen-self-gate-${SID2}.count"
out=$(make_input "mix deps.get" "developer-phoenix-backend" "$SID2" | bash "$HOOK" 2>/dev/null || true)
assert_not_contains "non-CI command ALLOWED" '"permissionDecision"' "$out"
rm -f "/tmp/codegen-self-gate-${SID2}.count"

# ── Test 3: 1st CI invocation → ALLOW (count=1) ──────────────────────────────
SID3="sid3-$$-$(date -u +%s)"
rm -f "/tmp/codegen-self-gate-${SID3}.count"
out=$(make_input "mix test test/foo_test.exs" "developer-phoenix-backend" "$SID3" | bash "$HOOK" 2>/dev/null || true)
assert_not_contains "1st CI invocation (count=1) ALLOWED" '"permissionDecision"' "$out"
count=$(cat "/tmp/codegen-self-gate-${SID3}.count" 2>/dev/null || echo 0)
[ "$count" = "1" ] && {
    [ -n "${VERBOSE:-}" ] && printf 'PASS: counter incremented to 1\n'
    pass=$((pass + 1))
} || {
    printf 'FAIL: counter expected 1, got %s\n' "$count"
    fail=$((fail + 1))
}
rm -f "/tmp/codegen-self-gate-${SID3}.count"

# ── Test 4: 3rd CI invocation → BLOCK ────────────────────────────────────────
SID4="sid4-$$-$(date -u +%s)"
printf '2' >"/tmp/codegen-self-gate-${SID4}.count"
out=$(make_input "make ci" "developer-phoenix-frontend" "$SID4" | bash "$HOOK" 2>/dev/null || true)
assert_contains "3rd CI invocation BLOCKED" '"permissionDecision"' "$out"
assert_contains "3rd CI block mentions LoopGate handoff" "LoopGate runs the full gate" "$out"
rm -f "/tmp/codegen-self-gate-${SID4}.count"

# ── Test 5: make ci pattern matched ──────────────────────────────────────────
SID5="sid5-$$-$(date -u +%s)"
printf '2' >"/tmp/codegen-self-gate-${SID5}.count"
out=$(make_input "make ci" "developer-static" "$SID5" | bash "$HOOK" 2>/dev/null || true)
assert_contains "make ci at count=3 BLOCKED" '"permissionDecision"' "$out"
rm -f "/tmp/codegen-self-gate-${SID5}.count"

# ── Test 6: mix credo bypasses cap — ALWAYS ALLOWED ─────────────────────────
# mix credo is cheap/required before handoff; cap does not apply.
SID6="sid6-$$-$(date -u +%s)"
printf '2' >"/tmp/codegen-self-gate-${SID6}.count"
out=$(make_input "mix credo --strict" "developer-phoenix-backend" "$SID6" | bash "$HOOK" 2>/dev/null || true)
assert_not_contains "mix credo at count=3 STILL ALLOWED (bypasses cap)" '"permissionDecision"' "$out"
rm -f "/tmp/codegen-self-gate-${SID6}.count"

# ── Test 6b: mix credo bypasses cap even at count=10 ────────────────────────
SID6B="sid6b-$$-$(date -u +%s)"
printf '10' >"/tmp/codegen-self-gate-${SID6B}.count"
out=$(make_input "mix credo --strict path/to/file.ex" "developer-phoenix-backend" "$SID6B" | bash "$HOOK" 2>/dev/null || true)
assert_not_contains "mix credo scoped at count=10 STILL ALLOWED" '"permissionDecision"' "$out"
rm -f "/tmp/codegen-self-gate-${SID6B}.count"

# ── Test 6c: make ci IS still blocked after 3 calls ─────────────────────────
SID6C="sid6c-$$-$(date -u +%s)"
printf '2' >"/tmp/codegen-self-gate-${SID6C}.count"
out=$(make_input "make ci" "developer-phoenix-backend" "$SID6C" | bash "$HOOK" 2>/dev/null || true)
assert_contains "make ci at count=3 BLOCKED (cap still applies)" '"permissionDecision"' "$out"
rm -f "/tmp/codegen-self-gate-${SID6C}.count"

# ── Test 7: developer-static also gated ──────────────────────────────────────
SID7="sid7-$$-$(date -u +%s)"
printf '2' >"/tmp/codegen-self-gate-${SID7}.count"
out=$(make_input "make test" "developer-static" "$SID7" | bash "$HOOK" 2>/dev/null || true)
assert_contains "developer-static at count=3 BLOCKED" '"permissionDecision"' "$out"
rm -f "/tmp/codegen-self-gate-${SID7}.count"

# ── Test 8: mix format matched ───────────────────────────────────────────────
SID8="sid8-$$-$(date -u +%s)"
printf '2' >"/tmp/codegen-self-gate-${SID8}.count"
out=$(make_input "mix format --check-formatted" "developer-phoenix-backend" "$SID8" | bash "$HOOK" 2>/dev/null || true)
assert_contains "mix format at count=3 BLOCKED" '"permissionDecision"' "$out"
rm -f "/tmp/codegen-self-gate-${SID8}.count"

# ── Test 9: codegen-log write narrating "make ci" in heredoc body → ALLOW, no counter bump ──
SID9="sid9-$$-$(date -u +%s)"
rm -f "/tmp/codegen-self-gate-${SID9}.count"
LOG_CMD='codegen-log section --slug test --body @- <<'"'"'EOF'"'"'
## developer-phoenix-backend Section
Ran make ci and mix test three times, all green.
EOF'
out=$(make_input "$LOG_CMD" "developer-phoenix-backend" "$SID9" | bash "$HOOK" 2>/dev/null || true)
assert_not_contains "codegen-log write narrating gated phrase ALLOWED" '"permissionDecision"' "$out"
if [ -f "/tmp/codegen-self-gate-${SID9}.count" ]; then
    printf 'FAIL: codegen-log write must NOT create/increment counter file\n'
    fail=$((fail + 1))
else
    [ -n "${VERBOSE:-}" ] && printf 'PASS: codegen-log write did not touch counter file\n'
    pass=$((pass + 1))
fi
rm -f "/tmp/codegen-self-gate-${SID9}.count"

# ── Test 10: real standalone make ci still denies/counts unchanged at count=3 ──
SID10="sid10-$$-$(date -u +%s)"
printf '2' >"/tmp/codegen-self-gate-${SID10}.count"
out=$(make_input "make ci" "developer-phoenix-backend" "$SID10" | bash "$HOOK" 2>/dev/null || true)
assert_contains "real make ci at count=3 STILL BLOCKED" '"permissionDecision"' "$out"
rm -f "/tmp/codegen-self-gate-${SID10}.count"

# ── Test 10b: mention of "mix test" in a grep pattern → ALLOW, no counter bump ──
SID10B="sid10b-$$-$(date -u +%s)"
rm -f "/tmp/codegen-self-gate-${SID10B}.count"
out=$(make_input 'grep -n "mix test" README.md' "developer-phoenix-backend" "$SID10B" | bash "$HOOK" 2>/dev/null || true)
assert_not_contains "mention of 'mix test' in grep pattern ALLOWED (not counted)" '"permissionDecision"' "$out"
if [ -f "/tmp/codegen-self-gate-${SID10B}.count" ]; then
    printf 'FAIL: mention must NOT create/increment counter file\n'
    fail=$((fail + 1))
else
    [ -n "${VERBOSE:-}" ] && printf 'PASS: mention did not touch counter file\n'
    pass=$((pass + 1))
fi
rm -f "/tmp/codegen-self-gate-${SID10B}.count"

# ── Test 10c: mention of "make ci" in an echo string → ALLOW, no counter bump ──
SID10C="sid10c-$$-$(date -u +%s)"
rm -f "/tmp/codegen-self-gate-${SID10C}.count"
out=$(make_input 'echo "run make ci first"' "developer-phoenix-backend" "$SID10C" | bash "$HOOK" 2>/dev/null || true)
assert_not_contains "mention of 'make ci' in echo string ALLOWED (not counted)" '"permissionDecision"' "$out"
if [ -f "/tmp/codegen-self-gate-${SID10C}.count" ]; then
    printf 'FAIL: mention must NOT create/increment counter file\n'
    fail=$((fail + 1))
else
    [ -n "${VERBOSE:-}" ] && printf 'PASS: mention did not touch counter file\n'
    pass=$((pass + 1))
fi
rm -f "/tmp/codegen-self-gate-${SID10C}.count"

# ── Loop-mode tests (CODEGEN_LOOP=1): progress-bounded self-verify ─────────
# Real tmpdir git fixture so the tree-signature command is exercised for
# real (not stubbed).
LOOP_TMPDIR=$(mktemp -d)
trap 'rm -rf "$LOOP_TMPDIR"' EXIT
git -C "$LOOP_TMPDIR" init -q
git -C "$LOOP_TMPDIR" config user.email "test@example.com"
git -C "$LOOP_TMPDIR" config user.name "Test"
git -C "$LOOP_TMPDIR" config commit.gpgsign false
printf 'hello' >"$LOOP_TMPDIR/a.txt"
git -C "$LOOP_TMPDIR" add a.txt
git -C "$LOOP_TMPDIR" commit -q -m init

make_loop_input() {
    local cmd="$1"
    local agent="${2:-developer-phoenix-backend}"
    local sid="${3:-test-session-$$}"
    local cwd="${4:-$LOOP_TMPDIR}"
    jq -n \
        --arg cmd "$cmd" \
        --arg agent "$agent" \
        --arg sid "$sid" \
        --arg cwd "$cwd" \
        '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":$cmd},"agent_type":$agent,"agent_id":"abc","session_id":$sid,"cwd":$cwd}'
}

# ── Test 11: loop-mode, first run → ALLOW (RED-then-GREEN: prove allow fires) ──
SID11="sid11-$$-$(date -u +%s)"
rm -f "/tmp/codegen-self-gate-${SID11}.sig"
out=$(make_loop_input "make test" "developer-phoenix-backend" "$SID11" | CODEGEN_LOOP=1 bash "$HOOK" 2>/dev/null || true)
assert_not_contains "loop-mode first run ALLOWED" '"permissionDecision"' "$out"
[ -f "/tmp/codegen-self-gate-${SID11}.sig" ] && {
    [ -n "${VERBOSE:-}" ] && printf 'PASS: loop-mode .sig file written on first run\n'
    pass=$((pass + 1))
} || {
    printf 'FAIL: loop-mode .sig file not written on first run\n'
    fail=$((fail + 1))
}
rm -f "/tmp/codegen-self-gate-${SID11}.sig"

# ── Test 12: loop-mode, tree changed since last run → ALLOW ────────────────
SID12="sid12-$$-$(date -u +%s)"
rm -f "/tmp/codegen-self-gate-${SID12}.sig"
out=$(make_loop_input "make test" "developer-phoenix-backend" "$SID12" | CODEGEN_LOOP=1 bash "$HOOK" 2>/dev/null || true)
assert_not_contains "loop-mode 1st run (baseline) ALLOWED" '"permissionDecision"' "$out"
# Make a real edit to the tree so the content signature changes.
printf 'goodbye' >"$LOOP_TMPDIR/b.txt"
out2=$(make_loop_input "make test" "developer-phoenix-backend" "$SID12" | CODEGEN_LOOP=1 bash "$HOOK" 2>/dev/null || true)
assert_not_contains "loop-mode 2nd run after tree edit (progress) ALLOWED" '"permissionDecision"' "$out2"
rm -f "$LOOP_TMPDIR/b.txt"
rm -f "/tmp/codegen-self-gate-${SID12}.sig"

# ── Test 12b: loop-mode, EDIT TO AN ALREADY-TRACKED FILE's CONTENT (not a new
# untracked file) since last run → ALLOW. Regression for a bug where the
# signature hashed only `git ls-files -oc` (the path LIST), so modifying an
# existing tracked file's bytes left the path set — and thus the signature —
# unchanged, falsely denying as a "pure spin" despite a real fixing edit.
SID12B="sid12b-$$-$(date -u +%s)"
rm -f "/tmp/codegen-self-gate-${SID12B}.sig"
out=$(make_loop_input "make test" "developer-phoenix-backend" "$SID12B" | CODEGEN_LOOP=1 bash "$HOOK" 2>/dev/null || true)
assert_not_contains "loop-mode tracked-edit 1st run (baseline) ALLOWED" '"permissionDecision"' "$out"
# Edit the CONTENT of the already-tracked a.txt (no new path introduced).
printf 'hello world' >"$LOOP_TMPDIR/a.txt"
out2=$(make_loop_input "make test" "developer-phoenix-backend" "$SID12B" | CODEGEN_LOOP=1 bash "$HOOK" 2>/dev/null || true)
assert_not_contains "loop-mode 2nd run after TRACKED-FILE content edit (progress) ALLOWED" '"permissionDecision"' "$out2"
git -C "$LOOP_TMPDIR" checkout -q -- a.txt
rm -f "/tmp/codegen-self-gate-${SID12B}.sig"

# ── Test 13: loop-mode, tree UNCHANGED since last run → DENY (spin) ────────
# RED-then-GREEN: this is the case the progress bound exists to catch — a
# repeat gate run with zero tree change must be denied.
SID13="sid13-$$-$(date -u +%s)"
rm -f "/tmp/codegen-self-gate-${SID13}.sig"
out=$(make_loop_input "make test" "developer-phoenix-backend" "$SID13" | CODEGEN_LOOP=1 bash "$HOOK" 2>/dev/null || true)
assert_not_contains "loop-mode 1st run (baseline, no edit yet) ALLOWED" '"permissionDecision"' "$out"
# No edit this time — same tree, same signature.
out2=$(make_loop_input "make test" "developer-phoenix-backend" "$SID13" | CODEGEN_LOOP=1 bash "$HOOK" 2>/dev/null || true)
assert_contains "loop-mode 2nd run with NO tree change DENIED (spin)" '"permissionDecision"' "$out2"
assert_contains "loop-mode spin-deny mentions making an edit" 'Make an edit' "$out2"
rm -f "/tmp/codegen-self-gate-${SID13}.sig"

# ── Test 14: loop-mode, hard ceiling (15) denies regardless of progress ────
SID14="sid14-$$-$(date -u +%s)"
rm -f "/tmp/codegen-self-gate-${SID14}.sig"
# Pre-seed the .sig state file at count=14 (one below the ceiling) with a
# signature that will not match the next real computed signature (forces the
# "progress" branch to be the one under test, not the spin branch).
printf 'bogus-prior-signature\n14\n' >"/tmp/codegen-self-gate-${SID14}.sig"
out=$(make_loop_input "make test" "developer-phoenix-backend" "$SID14" | CODEGEN_LOOP=1 bash "$HOOK" 2>/dev/null || true)
assert_contains "loop-mode hard ceiling (15) DENIED even with progress" '"permissionDecision"' "$out"
assert_contains "loop-mode ceiling-deny mentions hard ceiling" 'hard ceiling' "$out"
rm -f "/tmp/codegen-self-gate-${SID14}.sig"

# ── Test 15: legacy mode (CODEGEN_LOOP unset) count-of-3 cap unchanged ─────
SID15="sid15-$$-$(date -u +%s)"
printf '2' >"/tmp/codegen-self-gate-${SID15}.count"
out=$(make_input "make ci" "developer-phoenix-backend" "$SID15" | env -u CODEGEN_LOOP bash "$HOOK" 2>/dev/null || true)
assert_contains "legacy mode still BLOCKED at count=3 with CODEGEN_LOOP unset" '"permissionDecision"' "$out"
rm -f "/tmp/codegen-self-gate-${SID15}.count"

# ── Test 16: loop-mode, SAME tree but a NEW CODEGEN_RESUME_ATTEMPT token → ALLOW ──
# RED-then-GREEN: without the resume-token check this would DENY (same tree =
# "spin"), but a fresh resume token means the developer just woke up inside a
# resumed session and has not had a chance to make the fixing edit yet.
SID16="sid16-$$-$(date -u +%s)"
rm -f "/tmp/codegen-self-gate-${SID16}.sig"
out=$(make_loop_input "make test" "developer-phoenix-backend" "$SID16" | CODEGEN_LOOP=1 bash "$HOOK" 2>/dev/null || true)
assert_not_contains "loop-mode 1st run (baseline, no edit yet) ALLOWED" '"permissionDecision"' "$out"
# No tree edit — but a NEW resume token this time.
out2=$(make_loop_input "make test" "developer-phoenix-backend" "$SID16" | CODEGEN_RESUME_ATTEMPT=resume-tok-a CODEGEN_LOOP=1 bash "$HOOK" 2>/dev/null || true)
assert_not_contains "loop-mode 2nd run, same tree, NEW resume token ALLOWED (not a spin)" '"permissionDecision"' "$out2"
rm -f "/tmp/codegen-self-gate-${SID16}.sig"

# ── Test 17: loop-mode, SAME tree AND the SAME resume token again → DENY (spin) ──
# A resumed session's SECOND gate check with no tree change and the SAME
# resume token is a genuine spin — the resume-token allowance is one-shot per
# token, not a standing bypass.
SID17="sid17-$$-$(date -u +%s)"
rm -f "/tmp/codegen-self-gate-${SID17}.sig"
out=$(make_loop_input "make test" "developer-phoenix-backend" "$SID17" | CODEGEN_RESUME_ATTEMPT=resume-tok-b CODEGEN_LOOP=1 bash "$HOOK" 2>/dev/null || true)
assert_not_contains "loop-mode 1st run under a resume token ALLOWED" '"permissionDecision"' "$out"
out2=$(make_loop_input "make test" "developer-phoenix-backend" "$SID17" | CODEGEN_RESUME_ATTEMPT=resume-tok-b CODEGEN_LOOP=1 bash "$HOOK" 2>/dev/null || true)
assert_contains "loop-mode 2nd run, SAME resume token, no tree change DENIED (spin)" '"permissionDecision"' "$out2"
rm -f "/tmp/codegen-self-gate-${SID17}.sig"

# ── Test 18: loop-mode, SAME tree but a DIFFERENT targeted test command →
# ALLOW (not a spin). RED-then-GREEN: the spin signature now folds in the
# normalized COMMAND, not just tree content — before this fix, running
# `mix test test/a_test.exs` then `mix test test/b_test.exs` against an
# unchanged tree denied as a "pure spin", even though it is two DIFFERENT
# targeted test files — exactly the idiom dev-no-ci.sh prescribes as safe
# ("Specific test files are OK: mix test test/path/file.exs").
SID18="sid18-$$-$(date -u +%s)"
rm -f "/tmp/codegen-self-gate-${SID18}.sig"
out=$(make_loop_input "mix test test/a_test.exs" "developer-phoenix-backend" "$SID18" | CODEGEN_LOOP=1 bash "$HOOK" 2>/dev/null || true)
assert_not_contains "loop-mode 1st run (mix test test/a_test.exs) ALLOWED" '"permissionDecision"' "$out"
out2=$(make_loop_input "mix test test/b_test.exs" "developer-phoenix-backend" "$SID18" | CODEGEN_LOOP=1 bash "$HOOK" 2>/dev/null || true)
assert_not_contains "loop-mode 2nd run, SAME tree, DIFFERENT targeted test file ALLOWED (not a spin)" '"permissionDecision"' "$out2"
rm -f "/tmp/codegen-self-gate-${SID18}.sig"

# ── Test 19: loop-mode, SAME tree AND the SAME command again → DENY (spin).
# Confirms the D6 fix did not weaken the ORIGINAL spin detection — repeating
# the identical command against an unchanged tree is still a genuine spin.
SID19="sid19-$$-$(date -u +%s)"
rm -f "/tmp/codegen-self-gate-${SID19}.sig"
out=$(make_loop_input "mix test test/a_test.exs" "developer-phoenix-backend" "$SID19" | CODEGEN_LOOP=1 bash "$HOOK" 2>/dev/null || true)
assert_not_contains "loop-mode 1st run (mix test test/a_test.exs) ALLOWED" '"permissionDecision"' "$out"
out2=$(make_loop_input "mix test test/a_test.exs" "developer-phoenix-backend" "$SID19" | CODEGEN_LOOP=1 bash "$HOOK" 2>/dev/null || true)
assert_contains "loop-mode 2nd run, SAME tree, SAME command DENIED (spin)" '"permissionDecision"' "$out2"
rm -f "/tmp/codegen-self-gate-${SID19}.sig"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
