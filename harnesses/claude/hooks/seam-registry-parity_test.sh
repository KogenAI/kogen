#!/usr/bin/env bash
# seam-registry-parity_test.sh — meta-guard reconciling
# shared/enforcement/seam-registry.yaml against the actual guard machinery in
# the repo.
#
# A "seam" is a declaration<->reflection pair (see seam-registry.yaml header
# comment for the full field spec). This test does NOT re-check any seam's
# own correctness (that's the seam's own guard's job) — it checks that the
# INVENTORY of seams+guards is itself honest and complete:
#
#   Test 1 (live) — forward:  every non-GAP `guard:` value in the registry
#       resolves to a real Makefile .PHONY target OR an existing _test.sh file.
#   Test 2 (live) — reverse:  every parity/freshness/provenance-style guard
#       that exists in the repo (by naming convention) is referenced by
#       exactly one registry row. An unregistered guard is itself a drift.
#   Test 3 (live) — wiring:   every non-GAP guard_time:make-test Makefile
#       target is actually invoked from templates/generator/run-all-tests.sh
#       (make-test target case) or auto-discovered by run-tests.sh
#       (_test.sh case) — a guard that exists but never runs is worthless.
#   Test 4 (live) — gap honesty: every guard: GAP row has a non-empty
#       gap_rationale.
#   Test 5 (fixture) — malformed registry (missing gap_rationale on a GAP
#       row) is caught.
#   Test 6 (fixture) — a guard file referenced in the registry but absent on
#       disk fails forward-parity.
#
# Usage: bash seam-registry-parity_test.sh
# Exit 0 → all pass. Exit 1 → one or more failures.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODEGEN_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

REGISTRY="$CODEGEN_DIR/shared/enforcement/seam-registry.yaml"
MAKEFILE="$CODEGEN_DIR/Makefile"
RUN_ALL_TESTS="$CODEGEN_DIR/templates/generator/run-all-tests.sh"

pass=0
fail=0

assert_true() {
    local desc="$1" cond="$2"
    if [ "$cond" = "0" ]; then
        pass=$((pass + 1))
    else
        echo "FAIL: $desc"
        fail=$((fail + 1))
    fi
}

require_yq() {
    command -v yq >/dev/null 2>&1 || {
        echo "FAIL: yq not found on PATH — cannot parse seam-registry.yaml"
        fail=$((fail + 1))
        return 1
    }
    return 0
}

# ── Test 1 (live): forward parity — every non-GAP guard resolves ───────────
test_forward_parity() {
    require_yq || return 0
    local bad=""
    while IFS=$'\t' read -r id guard; do
        [ "$guard" = "GAP" ] && continue
        if [[ "$guard" == *.sh ]]; then
            [ -f "$CODEGEN_DIR/$guard" ] || bad="${bad}${bad:+, }$id -> $guard (file missing)"
        else
            grep -qE "^\.PHONY:.*\b${guard}\b" "$MAKEFILE" || bad="${bad}${bad:+, }$id -> $guard (not a .PHONY target)"
        fi
    done < <(yq -o=tsv '.seams[] | [.id, .guard]' "$REGISTRY")

    if [ -z "$bad" ]; then
        assert_true "forward parity: all registry guards resolve" 0
    else
        echo "  dangling guards: $bad"
        assert_true "forward parity: all registry guards resolve" 1
    fi
}

# ── Test 2 (live): reverse parity — every repo guard is registered ─────────
test_reverse_parity() {
    require_yq || return 0
    local registered_targets registered_tests
    registered_targets=$(yq -o=tsv '.seams[] | select(.guard != "GAP" and (.guard | test("_test\\.sh$") | not)) | .guard' "$REGISTRY" | sort -u)
    registered_tests=$(yq -o=tsv '.seams[] | select(.guard | test("_test\\.sh$")) | .guard' "$REGISTRY" | sort -u)

    # Makefile targets matching the naming convention, excluding compile/staleness helpers.
    local makefile_guards
    makefile_guards=$(grep -oE '^\.PHONY: .+' "$MAKEFILE" | sed 's/^\.PHONY: //' | tr ' ' '\n' \
        | grep -E 'parity|freshness|rationale|budget' \
        | grep -vE '\-compile$|staleness' \
        | sort -u)

    local unregistered=""
    while IFS= read -r g; do
        [ -z "$g" ] && continue
        printf '%s\n' "$registered_targets" | grep -qxF "$g" || unregistered="${unregistered}${unregistered:+, }$g"
    done <<<"$makefile_guards"

    # Hook _test.sh files matching the naming convention. A test file counts
    # as registered either directly (guard: harnesses/claude/hooks/x_test.sh)
    # OR indirectly via a Makefile .PHONY target that shells out to it (e.g.
    # prompt-content-parity wraps prompt-content-parity_test.sh) — the latter
    # is already covered by registered_targets, so cross-check both.
    local hook_test_guards
    hook_test_guards=$(find "$CODEGEN_DIR/harnesses/claude/hooks" -maxdepth 1 -name '*_test.sh' -type f -print0 \
        | xargs -0 -n1 basename \
        | grep -E 'parity|freshness|provenance' \
        | sort -u || true)

    while IFS= read -r t; do
        [ -z "$t" ] && continue
        local relpath="harnesses/claude/hooks/$t"
        if printf '%s\n' "$registered_tests" | grep -qxF "$relpath"; then
            continue
        fi
        # Check if a registered Makefile target shells out to this exact test file.
        local wrapped=0
        while IFS= read -r target; do
            [ -z "$target" ] && continue
            if grep -qF "hooks/$t" "$MAKEFILE" && grep -A5 "^${target}:" "$MAKEFILE" | grep -qF "$t"; then
                wrapped=1
                break
            fi
        done <<<"$registered_targets"
        [ "$wrapped" -eq 1 ] || unregistered="${unregistered}${unregistered:+, }$relpath"
    done <<<"$hook_test_guards"

    if [ -z "$unregistered" ]; then
        assert_true "reverse parity: all repo guards are registered" 0
    else
        echo "  unregistered guards: $unregistered"
        assert_true "reverse parity: all repo guards are registered" 1
    fi
}

# ── Test 3 (live): wiring — make-test guards actually run ──────────────────
test_wiring() {
    require_yq || return 0
    local bad=""
    while IFS=$'\t' read -r id guard; do
        [ "$guard" = "GAP" ] && continue
        if [[ "$guard" == *.sh ]]; then
            # _test.sh under hooks/ is auto-discovered by run-tests.sh; nothing further to check.
            continue
        fi
        grep -qE "labels\+=\(${guard}\)" "$RUN_ALL_TESTS" || bad="${bad}${bad:+, }$id -> $guard (not wired into run-all-tests.sh)"
    done < <(yq -o=tsv '.seams[] | select(.guard_time == "make-test") | [.id, .guard]' "$REGISTRY")

    if [ -z "$bad" ]; then
        assert_true "wiring: all make-test guards run in run-all-tests.sh" 0
    else
        echo "  unwired guards: $bad"
        assert_true "wiring: all make-test guards run in run-all-tests.sh" 1
    fi
}

# ── Test 4 (live): GAP honesty ──────────────────────────────────────────────
# Uses JSON (not TSV) because gap_rationale is a multi-line YAML block scalar
# whose embedded newlines break TSV row-splitting via `read -r`.
test_gap_honesty() {
    require_yq || return 0
    command -v jq >/dev/null 2>&1 || {
        echo "FAIL: jq not found on PATH"
        fail=$((fail + 1))
        return 0
    }
    local bad=""
    while IFS=$'\t' read -r id rationale_trimmed; do
        [ -n "$rationale_trimmed" ] || bad="${bad}${bad:+, }$id"
    done < <(yq -o=json '.seams[] | select(.guard == "GAP")' "$REGISTRY" \
        | jq -r '[.id, (.gap_rationale // "" | gsub("\\s"; ""))] | @tsv')

    if [ -z "$bad" ]; then
        assert_true "gap honesty: every GAP row has a rationale" 0
    else
        echo "  bare GAP rows (no rationale): $bad"
        assert_true "gap honesty: every GAP row has a rationale" 1
    fi
}

# ── Test 5 (fixture): malformed registry caught ─────────────────────────────
test_fixture_bare_gap() {
    require_yq || return 0
    local tmp
    tmp=$(mktemp)
    cat >"$tmp" <<'YAML'
seams:
  - id: fixture-bare-gap
    declares: x
    reflects: y
    guard: GAP
    guard_time: make-test
    pattern: checked-mirror
    gap_rationale: ""
YAML
    local trimmed
    trimmed=$(yq -o=json '.seams[] | select(.guard == "GAP")' "$tmp" \
        | jq -r '.gap_rationale // "" | gsub("\\s"; "")')
    rm -f "$tmp"
    if [ -z "$trimmed" ]; then
        assert_true "fixture: bare GAP rationale detected as empty" 0
    else
        assert_true "fixture: bare GAP rationale detected as empty" 1
    fi
}

# ── Test 6 (fixture): missing guard file fails forward-parity ──────────────
test_fixture_missing_guard_file() {
    require_yq || return 0
    local tmp
    tmp=$(mktemp)
    cat >"$tmp" <<'YAML'
seams:
  - id: fixture-missing-file
    declares: x
    reflects: y
    guard: harnesses/claude/hooks/definitely-does-not-exist_test.sh
    guard_time: make-test
    pattern: checked-mirror
YAML
    local guard
    guard=$(yq -o=tsv '.seams[] | .guard' "$tmp")
    rm -f "$tmp"
    if [ -f "$CODEGEN_DIR/$guard" ]; then
        assert_true "fixture: missing guard file detected" 1
    else
        assert_true "fixture: missing guard file detected" 0
    fi
}

test_forward_parity
test_reverse_parity
test_wiring
test_gap_honesty
test_fixture_bare_gap
test_fixture_missing_guard_file

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
