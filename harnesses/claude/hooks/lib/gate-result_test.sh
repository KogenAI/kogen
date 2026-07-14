#!/usr/bin/env bash
# gate-result_test.sh — unit tests for gate-result.sh
#
# Tests every row of the verdict derivation table plus edge cases.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/gate-result.sh"

pass=0
fail=0

assert_eq() {
    local desc="$1"
    local expected="$2"
    local actual="$3"
    if [ "$expected" = "$actual" ]; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' "$desc" "$expected" "$actual"
        fail=$((fail + 1))
    fi
}

# Helper: invoke write_gate_result and return the verdict field
write_and_get_verdict() {
    local gate="$1" mode="$2" runner_found="$3" exit_code="$4"
    local execution_evidence="$5" expected_segments="$6"
    local render_verdict="$7" classification="${8:-}"
    local dir
    dir=$(mktemp -d)
    write_gate_result "$gate" "$mode" "abc1234" 3 \
        "$runner_found" "$exit_code" "$execution_evidence" "$expected_segments" \
        "$render_verdict" "$classification" \
        "2026-06-07T12:00:00Z" "2026-06-07T12:03:00Z" \
        "sessabc" "/tmp/gate.log" "$dir"
    jq -r '.verdict' "$dir/codegen/gate-pending/gate-result.json" 2>/dev/null
    rm -rf "$dir"
}

write_and_get_marker() {
    local gate="$1" mode="$2" runner_found="$3" exit_code="$4"
    local execution_evidence="$5" expected_segments="$6"
    local render_verdict="$7" classification="${8:-}"
    local dir
    dir=$(mktemp -d)
    write_gate_result "$gate" "$mode" "abc1234" 3 \
        "$runner_found" "$exit_code" "$execution_evidence" "$expected_segments" \
        "$render_verdict" "$classification" \
        "2026-06-07T12:00:00Z" "2026-06-07T12:03:00Z" \
        "sessabc" "/tmp/gate.log" "$dir"
    jq -r '.verdict_marker' "$dir/codegen/gate-pending/gate-result.json" 2>/dev/null
    rm -rf "$dir"
}

# ── Verdict derivation table ─────────────────────────────────────────────────

# Row 1: runner_found=false → failed
assert_eq "runner_found=false → verdict=failed" \
    "failed" "$(write_and_get_verdict 'make ci' short false 0 2 2 '' '')"
assert_eq "runner_found=false → marker=FAILED ❌" \
    "FAILED ❌" "$(write_and_get_marker 'make ci' short false 0 2 2 '' '')"

# Row 2: exit=126 → failed
assert_eq "exit=126 → verdict=failed" \
    "failed" "$(write_and_get_verdict 'make ci' short true 126 0 1 '' '')"

# Row 3: exit=127 → failed
assert_eq "exit=127 → verdict=failed" \
    "failed" "$(write_and_get_verdict 'make ci' short true 127 0 1 '' '')"

# Row 4: exit≠0, classification=seed-missing → inconclusive
assert_eq "exit≠0 seed-missing → verdict=inconclusive" \
    "inconclusive" "$(write_and_get_verdict 'make llm-phoenix' long true 1 1 1 '' 'seed-missing (file: /x/seed.bundle)')"
assert_eq "exit≠0 seed-missing → marker=INCONCLUSIVE ⚠️" \
    "INCONCLUSIVE ⚠️" "$(write_and_get_marker 'make llm-phoenix' long true 1 1 1 '' 'seed-missing (file: /x/seed.bundle)')"

# Row 5: exit≠0, classification=pool-exhaustion → inconclusive
assert_eq "exit≠0 pool-exhaustion → verdict=inconclusive" \
    "inconclusive" "$(write_and_get_verdict 'make ci' short true 1 1 1 '' 'pool-exhaustion')"

# Row 6: exit≠0 (other) → failed
assert_eq "exit≠0 other → verdict=failed" \
    "failed" "$(write_and_get_verdict 'make ci' short true 1 2 2 '' '')"

# Row 7: timeout → inconclusive
assert_eq "timeout → verdict=inconclusive" \
    "inconclusive" "$(write_and_get_verdict 'make ci' long true timeout 0 1 '' 'timeout-exceeded')"
assert_eq "timeout → marker=INCONCLUSIVE ⚠️" \
    "INCONCLUSIVE ⚠️" "$(write_and_get_marker 'make ci' long true timeout 0 1 '' 'timeout-exceeded')"

# Row 8: exit=0, execution_evidence < expected_segments → failed (no-op gate)
assert_eq "exit=0 evidence < expected → verdict=failed (no-op gate)" \
    "failed" "$(write_and_get_verdict 'true' short true 0 0 2 '' '')"
assert_eq "exit=0 evidence < expected → marker=FAILED ❌" \
    "FAILED ❌" "$(write_and_get_marker 'true' short true 0 0 2 '' '')"

# Row 9: exit=0, render_verdict=FAIL:* → failed
assert_eq "exit=0 render FAIL → verdict=failed" \
    "failed" "$(write_and_get_verdict 'make ci' short true 0 2 2 'FAIL:JS errors' '')"

# Row 10: exit=0, render_verdict=INCONCLUSIVE:* → inconclusive
assert_eq "exit=0 render INCONCLUSIVE → verdict=inconclusive" \
    "inconclusive" "$(write_and_get_verdict 'make ci' short true 0 2 2 'INCONCLUSIVE:browser-unavailable' '')"

# Row 11: exit=0, evidence ok, render=PASS → clear
assert_eq "exit=0 evidence ok render PASS → verdict=clear" \
    "clear" "$(write_and_get_verdict 'make ci' short true 0 2 2 'PASS' '')"
assert_eq "exit=0 evidence ok render PASS → marker=ALL CLEAR ✅" \
    "ALL CLEAR ✅" "$(write_and_get_marker 'make ci' short true 0 2 2 'PASS' '')"

# Row 12: exit=0, evidence ok, render empty → clear
assert_eq "exit=0 evidence ok render empty → verdict=clear" \
    "clear" "$(write_and_get_verdict 'make ci' short true 0 2 2 '' '')"

# Row 13: exit=0, expected_segments=0 (single-segment gate) → no evidence check, clear
assert_eq "exit=0 expected_segments=0 single gate → verdict=clear" \
    "clear" "$(write_and_get_verdict 'make ci' short true 0 1 0 '' '')"

# ── JSON structure validation ─────────────────────────────────────────────────

DIR_STRUCT=$(mktemp -d)
write_gate_result "make ci" "short" "a1b2c3d" 7 \
    "true" 0 2 2 "PASS" "" \
    "2026-06-07T12:00:00Z" "2026-06-07T12:03:11Z" \
    "abc123" "/tmp/gate.log" "$DIR_STRUCT"

RESULT_FILE="$DIR_STRUCT/codegen/gate-pending/gate-result.json"

assert_eq "result file exists" "true" "$([ -f "$RESULT_FILE" ] && echo true || echo false)"
assert_eq "json .gate field" "make ci" "$(jq -r '.gate' "$RESULT_FILE")"
assert_eq "json .mode field" "short" "$(jq -r '.mode' "$RESULT_FILE")"
assert_eq "json .base_sha field" "a1b2c3d" "$(jq -r '.base_sha' "$RESULT_FILE")"
assert_eq "json .diff_files_count field" "7" "$(jq -r '.diff_files_count' "$RESULT_FILE")"
assert_eq "json .runner_found field" "true" "$(jq -r '.runner_found' "$RESULT_FILE")"
assert_eq "json .exit field" "0" "$(jq -r '.exit' "$RESULT_FILE")"
assert_eq "json .execution_evidence field" "2" "$(jq -r '.execution_evidence' "$RESULT_FILE")"
assert_eq "json .expected_segments field" "2" "$(jq -r '.expected_segments' "$RESULT_FILE")"
assert_eq "json .render_verdict field" "PASS" "$(jq -r '.render_verdict' "$RESULT_FILE")"
assert_eq "json .verdict field" "clear" "$(jq -r '.verdict' "$RESULT_FILE")"
assert_eq "json .verdict_marker field" "ALL CLEAR ✅" "$(jq -r '.verdict_marker' "$RESULT_FILE")"
assert_eq "json .session_id field" "abc123" "$(jq -r '.session_id' "$RESULT_FILE")"
assert_eq "json .log field" "/tmp/gate.log" "$(jq -r '.log' "$RESULT_FILE")"
assert_eq "json .started field" "2026-06-07T12:00:00Z" "$(jq -r '.started' "$RESULT_FILE")"
assert_eq "json .ended field" "2026-06-07T12:03:11Z" "$(jq -r '.ended' "$RESULT_FILE")"

# ── gate_result_base_sha ──────────────────────────────────────────────────────

assert_eq "gate_result_base_sha reads written value" \
    "a1b2c3d" "$(gate_result_base_sha "$DIR_STRUCT")"

rm -rf "$DIR_STRUCT"

assert_eq "gate_result_base_sha missing file → empty" \
    "" "$(gate_result_base_sha /nonexistent/path)"

# ── gate_result_verdict ───────────────────────────────────────────────────────

# missing file → empty
assert_eq "gate_result_verdict missing file → empty" \
    "" "$(gate_result_verdict /nonexistent/path)"

# reads verdict from existing file
DIR_VER=$(mktemp -d)
mkdir -p "$DIR_VER/codegen/gate-pending"
printf '{"verdict":"clear"}' >"$DIR_VER/codegen/gate-pending/gate-result.json"
assert_eq "gate_result_verdict reads clear" "clear" "$(gate_result_verdict "$DIR_VER")"
rm -rf "$DIR_VER"

DIR_VER2=$(mktemp -d)
mkdir -p "$DIR_VER2/codegen/gate-pending"
printf '{"verdict":"failed"}' >"$DIR_VER2/codegen/gate-pending/gate-result.json"
assert_eq "gate_result_verdict reads failed" "failed" "$(gate_result_verdict "$DIR_VER2")"
rm -rf "$DIR_VER2"

DIR_VER3=$(mktemp -d)
mkdir -p "$DIR_VER3/codegen/gate-pending"
printf '{"verdict":"inconclusive"}' >"$DIR_VER3/codegen/gate-pending/gate-result.json"
assert_eq "gate_result_verdict reads inconclusive" "inconclusive" "$(gate_result_verdict "$DIR_VER3")"
rm -rf "$DIR_VER3"

# malformed JSON → empty
DIR_VER4=$(mktemp -d)
mkdir -p "$DIR_VER4/codegen/gate-pending"
printf 'not json at all' >"$DIR_VER4/codegen/gate-pending/gate-result.json"
assert_eq "gate_result_verdict malformed JSON → empty" "" "$(gate_result_verdict "$DIR_VER4" 2>/dev/null)"
rm -rf "$DIR_VER4"

# ── Durable gate-verdict history ─────────────────────────────────────────────

# Helper: invoke write_gate_result with sentinel present → history file appended
write_and_history() {
    local gate="$1" mode="$2" runner_found="$3" exit_code="$4"
    local execution_evidence="$5" expected_segments="$6"
    local render_verdict="$7" classification="${8:-}"
    local dir
    dir=$(mktemp -d)
    mkdir -p "$dir/shared/enforcement"
    touch "$dir/shared/enforcement/registry.yaml"
    write_gate_result "$gate" "$mode" "abc1234" 3 \
        "$runner_found" "$exit_code" "$execution_evidence" "$expected_segments" \
        "$render_verdict" "$classification" \
        "2026-06-07T12:00:00Z" "2026-06-07T12:03:00Z" \
        "sessabc" "/tmp/gate.log" "$dir"
    printf '%s' "$dir"
}

# sentinel present → gate-verdicts.jsonl created and has correct fields
DIR_HIST=$(write_and_history 'make test' short true 0 2 2 'PASS' '')
HIST_FILE="$DIR_HIST/codegen/logging/gate-verdicts.jsonl"
assert_eq "history file created when sentinel present" \
    "true" "$([ -f "$HIST_FILE" ] && echo true || echo false)"
assert_eq "history file .verdict=clear" \
    "clear" "$(jq -r '.verdict' "$HIST_FILE" 2>/dev/null)"
assert_eq "history file .gate=make test" \
    "make test" "$(jq -r '.gate' "$HIST_FILE" 2>/dev/null)"
rm -rf "$DIR_HIST"

# sentinel absent → gate-verdicts.jsonl NOT created
DIR_NO_HIST=$(mktemp -d)
write_gate_result 'make ci' short "abc1234" 3 \
    true 0 2 2 \
    '' '' \
    "2026-06-07T12:00:00Z" "2026-06-07T12:03:00Z" \
    "sessxyz" "/tmp/gate.log" "$DIR_NO_HIST"
assert_eq "history file NOT created when sentinel absent" \
    "false" "$([ -f "$DIR_NO_HIST/codegen/logging/gate-verdicts.jsonl" ] && echo true || echo false)"
rm -rf "$DIR_NO_HIST"

# ── extract_witness ───────────────────────────────────────────────────────────

WIT_EXUNIT=$(mktemp)
printf '  1) test foo (FooTest)\n     test/foo_test.exs:42\n     ** (RuntimeError) boom\n' >"$WIT_EXUNIT"
assert_eq "extract_witness ExUnit → located file:line present" \
    "true" "$(extract_witness "$WIT_EXUNIT" | grep -qF 'test/foo_test.exs:42' && echo true || echo false)"
rm -f "$WIT_EXUNIT"

WIT_CREDO=$(mktemp)
printf '┃ [W] ↗ lib/bar.ex:12:7 Pipe chain should...\n' >"$WIT_CREDO"
assert_eq "extract_witness credo → located file:line present" \
    "true" "$(extract_witness "$WIT_CREDO" | grep -qF 'lib/bar.ex:12' && echo true || echo false)"
rm -f "$WIT_CREDO"

WIT_DIAL=$(mktemp)
printf 'lib/baz.ex:88:no_return Function loop/0 has no local return.\n' >"$WIT_DIAL"
assert_eq "extract_witness dialyzer → located file:line present" \
    "true" "$(extract_witness "$WIT_DIAL" | grep -qF 'lib/baz.ex:88' && echo true || echo false)"
rm -f "$WIT_DIAL"

WIT_NONE=$(mktemp)
printf 'just some unparseable noise with no location at all\n' >"$WIT_NONE"
assert_eq "extract_witness unparseable → empty string" "" "$(extract_witness "$WIT_NONE")"
rm -f "$WIT_NONE"

assert_eq "extract_witness missing file → empty + exit 0" \
    "ok" "$(extract_witness /nonexistent/log.txt >/dev/null 2>&1 && echo ok || echo err)"

# write_gate_result with witness (16th positional) → .witness present + equal
DIR_WIT=$(mktemp -d)
write_gate_result "make test" "short" "abc1234" 3 \
    "true" 1 2 2 "" "" \
    "2026-06-07T12:00:00Z" "2026-06-07T12:03:00Z" \
    "sessw" "/tmp/gate.log" "$DIR_WIT" "test/foo_test.exs:42 — boom"
assert_eq "write_gate_result .witness field equals arg" \
    "test/foo_test.exs:42 — boom" \
    "$(jq -r '.witness' "$DIR_WIT/codegen/gate-pending/gate-result.json")"
rm -rf "$DIR_WIT"

# Legacy 15-arg caller (no witness) → .witness present and empty (default)
DIR_LEG=$(mktemp -d)
write_gate_result "make test" "short" "abc1234" 3 \
    "true" 0 2 2 "PASS" "" \
    "2026-06-07T12:00:00Z" "2026-06-07T12:03:00Z" \
    "sessl" "/tmp/gate.log" "$DIR_LEG"
assert_eq "write_gate_result 15-arg legacy → .witness empty (default)" \
    "" "$(jq -r '.witness' "$DIR_LEG/codegen/gate-pending/gate-result.json")"
rm -rf "$DIR_LEG"

# ── graded_tree_sha (17th positional) ───────────────────────────────────────

# write_gate_result with witness + graded_tree_sha (16th + 17th positional)
DIR_GTS=$(mktemp -d)
write_gate_result "make test" "short" "abc1234" 3 \
    "true" 0 2 2 "PASS" "" \
    "2026-06-07T12:00:00Z" "2026-06-07T12:03:00Z" \
    "sessg" "/tmp/gate.log" "$DIR_GTS" "" "deadbeef1234567890"
assert_eq "write_gate_result .graded_tree_sha field equals arg" \
    "deadbeef1234567890" \
    "$(jq -r '.graded_tree_sha' "$DIR_GTS/codegen/gate-pending/gate-result.json")"
assert_eq "gate_result_graded_tree_sha reads back the same value" \
    "deadbeef1234567890" \
    "$(gate_result_graded_tree_sha "$DIR_GTS")"
rm -rf "$DIR_GTS"

# Legacy 16-arg caller (witness only, no graded_tree_sha) → field present, empty
DIR_16=$(mktemp -d)
write_gate_result "make test" "short" "abc1234" 3 \
    "true" 1 2 2 "" "" \
    "2026-06-07T12:00:00Z" "2026-06-07T12:03:00Z" \
    "sess16" "/tmp/gate.log" "$DIR_16" "test/foo_test.exs:42 — boom"
assert_eq "write_gate_result 16-arg legacy → .graded_tree_sha empty (default)" \
    "" "$(jq -r '.graded_tree_sha' "$DIR_16/codegen/gate-pending/gate-result.json")"
rm -rf "$DIR_16"

# Legacy 15-arg caller (no witness, no graded_tree_sha) → both fields empty
DIR_15=$(mktemp -d)
write_gate_result "make test" "short" "abc1234" 3 \
    "true" 0 2 2 "PASS" "" \
    "2026-06-07T12:00:00Z" "2026-06-07T12:03:00Z" \
    "sess15" "/tmp/gate.log" "$DIR_15"
assert_eq "write_gate_result 15-arg legacy → .graded_tree_sha empty (default)" \
    "" "$(jq -r '.graded_tree_sha' "$DIR_15/codegen/gate-pending/gate-result.json")"

# gate_result_graded_tree_sha on a missing result file → ""
assert_eq "gate_result_graded_tree_sha missing file → empty" \
    "" "$(gate_result_graded_tree_sha "$(mktemp -d)")"
rm -rf "$DIR_15"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
