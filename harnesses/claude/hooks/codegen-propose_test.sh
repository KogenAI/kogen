#!/usr/bin/env bash
# codegen-propose_test.sh — unit tests for codegen-propose launcher.
#
# Uses PATH-stub codegen-analyze + codegen-call so no real analyzer scan or
# LLM call ever fires.
#
# (a) happy path — 2 qualifying clusters + 1 below threshold; stub
#     codegen-call returns a valid high-confidence proposed record for both
#     → proposals file has "Summary: 2 proposed / 0 declined-low-confidence /
#     0 errored" and 2 "(PROPOSED)" record blocks.
# (b) no clusters clear threshold → "no proposals above threshold" note,
#     exit 0.
# (c) codegen-call errors on cluster 1 → cluster-1 record error-marked,
#     cluster 2 still proposed, batch exit 0 (continue-past-failure).
# (d) decline path — stub returns confidence:low change:null → declined
#     record.
# (e) codegen-propose source contains zero --role tokens.
set -euo pipefail

HOOKS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODEGEN_ROOT="$(cd "$HOOKS_DIR/../../.." && pwd)"
CODEGEN_PROPOSE="$CODEGEN_ROOT/codegen-propose"

pass=0
fail=0

check() {
    local desc="$1"
    local expected="$2"
    local actual="$3"
    if [[ "$actual" == "$expected" ]]; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s — expected %q, got %q\n' "$desc" "$expected" "$actual"
        fail=$((fail + 1))
    fi
}

assert_contains() {
    local desc="$1"
    local haystack="$2"
    local needle="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s — expected to find %q\n  got: %s\n' "$desc" "$needle" "${haystack:0:600}"
        fail=$((fail + 1))
    fi
}

BASE_TMP="$(mktemp -d)"
cleanup() { rm -rf "$BASE_TMP"; }
trap cleanup EXIT

make_stub() {
    local path="$1"
    local body="$2"
    printf '#!/usr/bin/env bash\n%s\n' "$body" >"$path"
    chmod +x "$path"
}

# Build an isolated codegen-propose root: copy the real launcher, plus
# a fake harnesses/ dir (so path-derivation resolves) with the real
# propose-system-prompt.md + proposal.schema.json (unmodified, read-only
# consumption — codegen-call is stubbed so these files are never actually
# sent anywhere meaningful, but codegen-propose still validates @paths).
make_cp_root() {
    local name="$1"
    local dir="$BASE_TMP/$name"
    mkdir -p "$dir/harnesses/claude"
    cp "$CODEGEN_PROPOSE" "$dir/codegen-propose"
    chmod +x "$dir/codegen-propose"
    cp "$CODEGEN_ROOT/harnesses/claude/propose-system-prompt.md" "$dir/harnesses/claude/"
    cp "$CODEGEN_ROOT/harnesses/claude/proposal.schema.json" "$dir/harnesses/claude/"
    echo "$dir"
}

# Stub bin dir prepended to PATH: holds stub codegen-analyze + codegen-call.
make_stub_bin() {
    local name="$1"
    local dir="$BASE_TMP/${name}_bin"
    mkdir -p "$dir"
    echo "$dir"
}

# ─────────────────────────────────────────────────────────────────────────────
# Test (a): happy path — 2 qualifying + 1 below-threshold cluster
# ─────────────────────────────────────────────────────────────────────────────
CP_A="$(make_cp_root cp_a)"
BIN_A="$(make_stub_bin a)"

make_stub "$BIN_A/codegen-analyze" '
printf "%s\n" \
  "{\"counter\":\"forbidden_bash\",\"pattern_key\":\"cluster-one\",\"wasted_turns\":8,\"sessions\":2,\"top_evidence\":\"ev1\"}" \
  "{\"counter\":\"user_correction\",\"pattern_key\":\"cluster-two\",\"wasted_turns\":6,\"sessions\":1,\"top_evidence\":\"ev2\"}" \
  "{\"counter\":\"re_read\",\"pattern_key\":\"below-threshold\",\"wasted_turns\":1,\"sessions\":1,\"top_evidence\":\"ev3\"}"
'

CALL_COUNTER_FILE_A="$BASE_TMP/a_call_count"
echo 0 >"$CALL_COUNTER_FILE_A"
make_stub "$BIN_A/codegen-call" '
n=$(($(cat "'"$CALL_COUNTER_FILE_A"'") + 1))
echo "$n" > "'"$CALL_COUNTER_FILE_A"'"
printf "%s\n" "{\"result\":{\"status\":\"success\",\"value\":{\"cluster\":{\"counter\":\"forbidden_bash\",\"pattern_key\":\"x\",\"wasted_turns\":8},\"target_file\":\"harnesses/claude/tools-header/debug.txt\",\"anchor\":\"## Tools\",\"change\":{\"description\":\"add a line naming the forbidden command\"},\"rationale\":\"evidence shows repeated forbidden bash use\",\"confidence\":\"high\"},\"reason\":null,\"retry_meta\":null},\"usage\":{},\"error\":null,\"harness\":\"claude_code\"}"
'

actual_exit=0
OUT_A="$(PATH="$BIN_A:$PATH" "$CP_A/codegen-propose" --since 2026-01-01 2>&1)" || actual_exit=$?
check "(a) exits 0" "0" "$actual_exit"
assert_contains "(a) summary line" "$OUT_A" "Summary: 2 proposed / 0 declined-low-confidence / 0 errored"

PROPOSALS_FILE_A="$CP_A/codegen/analysis-proposals/20260101_$(date -u +%Y%m%d).md"
if [[ -f "$PROPOSALS_FILE_A" ]]; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: (a) proposals file exists\n'
    pass=$((pass + 1))
    CONTENT_A="$(cat "$PROPOSALS_FILE_A")"
    assert_contains "(a) proposals file has summary" "$CONTENT_A" "Summary: 2 proposed / 0 declined-low-confidence / 0 errored"
    assert_contains "(a) proposals file has cluster-one" "$CONTENT_A" "cluster-one"
    assert_contains "(a) proposals file has cluster-two" "$CONTENT_A" "cluster-two"
    PROPOSED_COUNT_A="$(printf '%s' "$CONTENT_A" | grep -c "(PROPOSED)")"
    check "(a) 2 PROPOSED record blocks" "2" "$PROPOSED_COUNT_A"
    BELOW_THRESHOLD_A=0
    [[ "$CONTENT_A" == *"below-threshold"* ]] && BELOW_THRESHOLD_A=1
    check "(a) below-threshold cluster excluded" "0" "$BELOW_THRESHOLD_A"
else
    printf 'FAIL: (a) proposals file exists — not found at %s\n' "$PROPOSALS_FILE_A"
    fail=$((fail + 1))
fi

# ─────────────────────────────────────────────────────────────────────────────
# Test (b): no clusters clear threshold
# ─────────────────────────────────────────────────────────────────────────────
CP_B="$(make_cp_root cp_b)"
BIN_B="$(make_stub_bin b)"

make_stub "$BIN_B/codegen-analyze" '
printf "%s\n" "{\"counter\":\"forbidden_bash\",\"pattern_key\":\"tiny\",\"wasted_turns\":1,\"sessions\":1,\"top_evidence\":\"ev\"}"
'
make_stub "$BIN_B/codegen-call" 'echo "should not be called" >&2; exit 1'

actual_exit=0
OUT_B="$(PATH="$BIN_B:$PATH" "$CP_B/codegen-propose" --since 2026-01-01 2>&1)" || actual_exit=$?
check "(b) exits 0" "0" "$actual_exit"
assert_contains "(b) no-proposals note" "$OUT_B" "no proposals above threshold"

# ─────────────────────────────────────────────────────────────────────────────
# Test (c): codegen-call errors on cluster 1, cluster 2 still proposed
# ─────────────────────────────────────────────────────────────────────────────
CP_C="$(make_cp_root cp_c)"
BIN_C="$(make_stub_bin c)"

make_stub "$BIN_C/codegen-analyze" '
printf "%s\n" \
  "{\"counter\":\"forbidden_bash\",\"pattern_key\":\"will-error\",\"wasted_turns\":10,\"sessions\":2,\"top_evidence\":\"ev1\"}" \
  "{\"counter\":\"user_correction\",\"pattern_key\":\"will-succeed\",\"wasted_turns\":9,\"sessions\":1,\"top_evidence\":\"ev2\"}"
'

CALL_COUNTER_FILE_C="$BASE_TMP/c_call_count"
echo 0 >"$CALL_COUNTER_FILE_C"
make_stub "$BIN_C/codegen-call" '
n=$(($(cat "'"$CALL_COUNTER_FILE_C"'") + 1))
echo "$n" > "'"$CALL_COUNTER_FILE_C"'"
if [ "$n" = "1" ]; then
  echo "simulated dispatch failure" >&2
  exit 1
fi
printf "%s\n" "{\"result\":{\"status\":\"success\",\"value\":{\"cluster\":{\"counter\":\"user_correction\",\"pattern_key\":\"will-succeed\",\"wasted_turns\":9},\"target_file\":\"shared/rules/roles/developer.md\",\"anchor\":\"## Discipline\",\"change\":{\"description\":\"clarify rule X\"},\"rationale\":\"grounded in evidence\",\"confidence\":\"medium\"},\"reason\":null,\"retry_meta\":null},\"usage\":{},\"error\":null,\"harness\":\"claude_code\"}"
'

actual_exit=0
OUT_C="$(PATH="$BIN_C:$PATH" "$CP_C/codegen-propose" --since 2026-01-01 2>&1)" || actual_exit=$?
check "(c) batch exits 0 despite one errored cluster" "0" "$actual_exit"
assert_contains "(c) summary shows 1 proposed / 0 declined / 1 errored" "$OUT_C" "Summary: 1 proposed / 0 declined-low-confidence / 1 errored"

PROPOSALS_FILE_C="$CP_C/codegen/analysis-proposals/20260101_$(date -u +%Y%m%d).md"
CONTENT_C="$(cat "$PROPOSALS_FILE_C" 2>/dev/null || true)"
assert_contains "(c) errored cluster marked" "$CONTENT_C" "will-error"
assert_contains "(c) errored marker present" "$CONTENT_C" "(ERRORED)"
assert_contains "(c) succeeded cluster proposed" "$CONTENT_C" "will-succeed"
assert_contains "(c) proposed marker present" "$CONTENT_C" "(PROPOSED)"

# RED proof: without the set+e/rc/set-e sandwich, a non-zero codegen-call
# would abort the whole script under `set -euo pipefail` before cluster 2 is
# ever processed. Confirm that behavior directly using a FRESH stub root
# (the shared BIN_C/CALL_COUNTER_FILE_C stub is stateful and already spent
# its first-call-fails behavior during the batch run above): a stub that
# always fails, invoked under bare `set -euo pipefail` with no sandwich,
# aborts the enclosing subshell.
BIN_RED="$(make_stub_bin red_probe)"
make_stub "$BIN_RED/codegen-call" 'echo "simulated dispatch failure" >&2; exit 1'
RED_PROBE_RC=0
(
    set -euo pipefail
    "$BIN_RED/codegen-call" --harness=claude_code --model=opus --effort=high \
        --system-prompt "@$CP_C/harnesses/claude/propose-system-prompt.md" \
        --json-schema "@$CP_C/harnesses/claude/proposal.schema.json" \
        -- "probe" >/dev/null 2>&1
) || RED_PROBE_RC=$?
check "(c) RED proof: stub call 1 alone exits non-zero under bare set -e" "1" "$RED_PROBE_RC"

# ─────────────────────────────────────────────────────────────────────────────
# Test (d): decline path — confidence:low, change:null
# ─────────────────────────────────────────────────────────────────────────────
CP_D="$(make_cp_root cp_d)"
BIN_D="$(make_stub_bin d)"

make_stub "$BIN_D/codegen-analyze" '
printf "%s\n" "{\"counter\":\"hook_intervention\",\"pattern_key\":\"unclear-cause\",\"wasted_turns\":7,\"sessions\":1,\"top_evidence\":\"ev\"}"
'
make_stub "$BIN_D/codegen-call" '
printf "%s\n" "{\"result\":{\"status\":\"success\",\"value\":{\"cluster\":{\"counter\":\"hook_intervention\",\"pattern_key\":\"unclear-cause\",\"wasted_turns\":7},\"target_file\":\"unknown\",\"anchor\":\"\",\"change\":null,\"rationale\":\"needs human investigation - evidence too sparse\",\"confidence\":\"low\"},\"reason\":null,\"retry_meta\":null},\"usage\":{},\"error\":null,\"harness\":\"claude_code\"}"
'

actual_exit=0
OUT_D="$(PATH="$BIN_D:$PATH" "$CP_D/codegen-propose" --since 2026-01-01 2>&1)" || actual_exit=$?
check "(d) exits 0" "0" "$actual_exit"
assert_contains "(d) summary shows 1 declined" "$OUT_D" "Summary: 0 proposed / 1 declined-low-confidence / 0 errored"

PROPOSALS_FILE_D="$CP_D/codegen/analysis-proposals/20260101_$(date -u +%Y%m%d).md"
CONTENT_D="$(cat "$PROPOSALS_FILE_D" 2>/dev/null || true)"
assert_contains "(d) declined marker present" "$CONTENT_D" "(DECLINED-LOW-CONFIDENCE)"

# ─────────────────────────────────────────────────────────────────────────────
# Test (e): codegen-propose source contains zero --role tokens
# ─────────────────────────────────────────────────────────────────────────────
ROLE_FLAG_COUNT="$(grep -c -- '--role' "$CODEGEN_PROPOSE" || true)"
ROLE_FLAG_COUNT="${ROLE_FLAG_COUNT:-0}"
check "(e) codegen-propose has zero --role tokens" "0" "$ROLE_FLAG_COUNT"

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Results: $pass passed, $fail failed"

if [[ "$fail" -gt 0 ]]; then
    exit 1
fi
exit 0
