#!/usr/bin/env bash
# tools-header-no-dup_test.sh — detector + fixture tests
#
# Verifies that no non-trivial line is byte-identical across both harness
# tools-header files for each mode. A shared non-trivial line signals that it
# belongs in harnesses/shared/prompt-bodies/<mode>.txt, not in each header.
#
# Exempt from the check:
#   - blank / whitespace-only lines
#   - markdown structural headings: ^[[:space:]]*#{1,6}[[:space:]]
#   - lines with fewer than 8 non-space characters (short labels, punctuation)
#
# Usage: bash tools-header-no-dup_test.sh
# Exit 0 → all pass. Exit 1 → one or more failures.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODEGEN_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

MIN_LEN=8

pass=0
fail=0

# ── helpers ──────────────────────────────────────────────────────────────────

is_exempt() {
    local line="$1"
    # blank / whitespace-only
    local stripped
    stripped=$(printf '%s' "$line" | tr -d '[:space:]')
    if [ -z "$stripped" ]; then
        return 0
    fi
    # markdown heading: ^[[:space:]]*#{1,6}[[:space:]]
    if printf '%s' "$line" | grep -qE '^[[:space:]]*#{1,6}[[:space:]]'; then
        return 0
    fi
    # fewer than MIN_LEN non-space chars
    if [ "${#stripped}" -lt "$MIN_LEN" ]; then
        return 0
    fi
    return 1
}

check_mode_headers() {
    local mode="$1"
    local claude_header="$2"
    local pi_header="$3"
    local body_file="$4"
    local mode_pass=0
    local mode_fail=0

    if [ ! -f "$claude_header" ] || [ ! -f "$pi_header" ]; then
        printf 'FAIL: %s — one or both header files missing\n' "$mode"
        fail=$((fail + 1))
        return
    fi

    # Find byte-identical non-blank lines present in both headers
    while IFS= read -r line; do
        if is_exempt "$line"; then
            continue
        fi
        printf 'FAIL: %s — line byte-identical in both headers, move to %s: "%s"\n' \
            "$mode" "$body_file" "$line"
        mode_fail=$((mode_fail + 1))
        fail=$((fail + 1))
    done < <(comm -12 \
        <(grep -v '^[[:space:]]*$' "$claude_header" | sort) \
        <(grep -v '^[[:space:]]*$' "$pi_header" | sort))

    if [ "$mode_fail" -eq 0 ]; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s — no non-trivial duplicate lines\n' "$mode"
        pass=$((pass + 1))
    fi
}

# ── Real-mode tests (Tests 1-4) ───────────────────────────────────────────────

check_mode_headers "build" \
    "$CODEGEN_DIR/harnesses/claude/tools-header/build.txt" \
    "$CODEGEN_DIR/harnesses/pi/tools-header/build.txt" \
    "harnesses/shared/prompt-bodies/build.txt"

check_mode_headers "debug" \
    "$CODEGEN_DIR/harnesses/claude/tools-header/debug.txt" \
    "$CODEGEN_DIR/harnesses/pi/tools-header/debug.txt" \
    "harnesses/shared/prompt-bodies/debug.txt"

check_mode_headers "shape" \
    "$CODEGEN_DIR/harnesses/claude/tools-header/shape.txt" \
    "$CODEGEN_DIR/harnesses/pi/tools-header/shape.txt" \
    "harnesses/shared/prompt-bodies/shape.txt"

check_mode_headers "ops" \
    "$CODEGEN_DIR/harnesses/claude/tools-header/ops.txt" \
    "$CODEGEN_DIR/harnesses/pi/tools-header/ops.txt" \
    "harnesses/shared/prompt-bodies/ops.txt"

# ── Synthetic-fixture tests ───────────────────────────────────────────────────
# Each fixture creates a temp dir with mock header files, runs the check,
# and asserts the expected pass/fail outcome.

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# ── Test 5: duplicated non-trivial line → FAIL with correct message ───────────
{
    mkdir -p "$TMP_DIR/t5/claude" "$TMP_DIR/t5/pi"
    printf '## Tools\n\nThis is a duplicated non-trivial sentence that should move to body.\n' \
        >"$TMP_DIR/t5/claude/build.txt"
    printf '## Tools\n\nThis is a duplicated non-trivial sentence that should move to body.\n' \
        >"$TMP_DIR/t5/pi/build.txt"

    out=$(
        fail_inner=0
        pass_inner=0
        while IFS= read -r line; do
            stripped=$(printf '%s' "$line" | tr -d '[:space:]')
            [ -z "$stripped" ] && continue
            printf '%s' "$line" | grep -qE '^[[:space:]]*#{1,6}[[:space:]]' && continue
            [ "${#stripped}" -lt "$MIN_LEN" ] && continue
            printf 'FAIL: build — line byte-identical in both headers, move to harnesses/shared/prompt-bodies/build.txt: "%s"\n' "$line"
            fail_inner=$((fail_inner + 1))
        done < <(comm -12 \
            <(grep -v '^[[:space:]]*$' "$TMP_DIR/t5/claude/build.txt" | sort) \
            <(grep -v '^[[:space:]]*$' "$TMP_DIR/t5/pi/build.txt" | sort))
        printf '%d' "$fail_inner"
    )

    fail_count="${out##*$'\n'}"
    # out from subshell contains FAIL lines + the final count number
    msg_part=$(printf '%s' "$out" | grep '^FAIL:' | head -1)

    if printf '%s' "$msg_part" | grep -qF 'harnesses/shared/prompt-bodies/build.txt'; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: Test 5 — duplicate line detected with correct body path in message\n'
        pass=$((pass + 1))
    else
        printf 'FAIL: Test 5 — duplicate line not detected or message missing body path. Got: %s\n' "$msg_part"
        fail=$((fail + 1))
    fi
    if printf '%s' "$msg_part" | grep -qF 'duplicated non-trivial sentence'; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: Test 5 — duplicate line message names the offending line\n'
        pass=$((pass + 1))
    else
        printf 'FAIL: Test 5 — duplicate line message does not name the offending line. Got: %s\n' "$msg_part"
        fail=$((fail + 1))
    fi
}

# ── Test 6: heading-only duplicate → PASS (headings are exempt) ──────────────
{
    mkdir -p "$TMP_DIR/t6/claude" "$TMP_DIR/t6/pi"
    printf '## Tools\n\nUnique claude-specific line.\n' >"$TMP_DIR/t6/claude/ops.txt"
    printf '## Tools\n\nUnique pi-specific line.\n' >"$TMP_DIR/t6/pi/ops.txt"

    dup_count=0
    while IFS= read -r line; do
        stripped=$(printf '%s' "$line" | tr -d '[:space:]')
        [ -z "$stripped" ] && continue
        printf '%s' "$line" | grep -qE '^[[:space:]]*#{1,6}[[:space:]]' && continue
        [ "${#stripped}" -lt "$MIN_LEN" ] && continue
        dup_count=$((dup_count + 1))
    done < <(comm -12 \
        <(grep -v '^[[:space:]]*$' "$TMP_DIR/t6/claude/ops.txt" | sort) \
        <(grep -v '^[[:space:]]*$' "$TMP_DIR/t6/pi/ops.txt" | sort))

    if [ "$dup_count" -eq 0 ]; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: Test 6 — heading-only duplicate is exempt\n'
        pass=$((pass + 1))
    else
        printf 'FAIL: Test 6 — heading-only duplicate was flagged (should be exempt)\n'
        fail=$((fail + 1))
    fi
}

# ── Test 7: blank-line duplicate → PASS (blank lines are exempt) ─────────────
{
    mkdir -p "$TMP_DIR/t7/claude" "$TMP_DIR/t7/pi"
    printf '## Tools\n\n\n\nUnique claude line here for debug mode.\n' >"$TMP_DIR/t7/claude/debug.txt"
    printf '## Tools\n\n\n\nUnique pi line here for debug mode.\n' >"$TMP_DIR/t7/pi/debug.txt"

    dup_count=0
    while IFS= read -r line; do
        stripped=$(printf '%s' "$line" | tr -d '[:space:]')
        [ -z "$stripped" ] && continue
        printf '%s' "$line" | grep -qE '^[[:space:]]*#{1,6}[[:space:]]' && continue
        [ "${#stripped}" -lt "$MIN_LEN" ] && continue
        dup_count=$((dup_count + 1))
    done < <(comm -12 \
        <(grep -v '^[[:space:]]*$' "$TMP_DIR/t7/claude/debug.txt" | sort) \
        <(grep -v '^[[:space:]]*$' "$TMP_DIR/t7/pi/debug.txt" | sort))

    if [ "$dup_count" -eq 0 ]; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: Test 7 — blank-line duplicates are exempt\n'
        pass=$((pass + 1))
    else
        printf 'FAIL: Test 7 — blank-line duplicates were flagged (should be exempt)\n'
        fail=$((fail + 1))
    fi
}

# ── Test 8: short-line (<8 non-space chars) duplicate → PASS ─────────────────
{
    mkdir -p "$TMP_DIR/t8/claude" "$TMP_DIR/t8/pi"
    # "ok" has 2 non-space chars — well below 8
    printf '## Tools\n\nok\nUnique claude line in shape mode.\n' >"$TMP_DIR/t8/claude/shape.txt"
    printf '## Tools\n\nok\nUnique pi line in shape mode.\n' >"$TMP_DIR/t8/pi/shape.txt"

    dup_count=0
    while IFS= read -r line; do
        stripped=$(printf '%s' "$line" | tr -d '[:space:]')
        [ -z "$stripped" ] && continue
        printf '%s' "$line" | grep -qE '^[[:space:]]*#{1,6}[[:space:]]' && continue
        [ "${#stripped}" -lt "$MIN_LEN" ] && continue
        dup_count=$((dup_count + 1))
    done < <(comm -12 \
        <(grep -v '^[[:space:]]*$' "$TMP_DIR/t8/claude/shape.txt" | sort) \
        <(grep -v '^[[:space:]]*$' "$TMP_DIR/t8/pi/shape.txt" | sort))

    if [ "$dup_count" -eq 0 ]; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: Test 8 — short-line duplicate is exempt\n'
        pass=$((pass + 1))
    else
        printf 'FAIL: Test 8 — short-line duplicate was flagged (should be exempt)\n'
        fail=$((fail + 1))
    fi
}

# ── Test 9: whitespace-only line → PASS ──────────────────────────────────────
{
    mkdir -p "$TMP_DIR/t9/claude" "$TMP_DIR/t9/pi"
    printf '## Tools\n\n   \n   \nUnique claude-only sentence in build mode.\n' >"$TMP_DIR/t9/claude/build.txt"
    printf '## Tools\n\n   \n   \nUnique pi-only sentence in build mode.\n' >"$TMP_DIR/t9/pi/build.txt"

    dup_count=0
    while IFS= read -r line; do
        stripped=$(printf '%s' "$line" | tr -d '[:space:]')
        [ -z "$stripped" ] && continue
        printf '%s' "$line" | grep -qE '^[[:space:]]*#{1,6}[[:space:]]' && continue
        [ "${#stripped}" -lt "$MIN_LEN" ] && continue
        dup_count=$((dup_count + 1))
    done < <(comm -12 \
        <(grep -v '^[[:space:]]*$' "$TMP_DIR/t9/claude/build.txt" | sort) \
        <(grep -v '^[[:space:]]*$' "$TMP_DIR/t9/pi/build.txt" | sort))

    if [ "$dup_count" -eq 0 ]; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: Test 9 — whitespace-only line is exempt\n'
        pass=$((pass + 1))
    else
        printf 'FAIL: Test 9 — whitespace-only line was flagged (should be exempt)\n'
        fail=$((fail + 1))
    fi
}

# ── Test 10: leading-space heading → PASS (heading regex handles leading spaces) ─
{
    mkdir -p "$TMP_DIR/t10/claude" "$TMP_DIR/t10/pi"
    printf '  ## Tools\n\nUnique claude content for ops.\n' >"$TMP_DIR/t10/claude/ops.txt"
    printf '  ## Tools\n\nUnique pi content for ops.\n' >"$TMP_DIR/t10/pi/ops.txt"

    dup_count=0
    while IFS= read -r line; do
        stripped=$(printf '%s' "$line" | tr -d '[:space:]')
        [ -z "$stripped" ] && continue
        printf '%s' "$line" | grep -qE '^[[:space:]]*#{1,6}[[:space:]]' && continue
        [ "${#stripped}" -lt "$MIN_LEN" ] && continue
        dup_count=$((dup_count + 1))
    done < <(comm -12 \
        <(grep -v '^[[:space:]]*$' "$TMP_DIR/t10/claude/ops.txt" | sort) \
        <(grep -v '^[[:space:]]*$' "$TMP_DIR/t10/pi/ops.txt" | sort))

    if [ "$dup_count" -eq 0 ]; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: Test 10 — leading-space heading is exempt\n'
        pass=$((pass + 1))
    else
        printf 'FAIL: Test 10 — leading-space heading was flagged (should be exempt)\n'
        fail=$((fail + 1))
    fi
}

# ── Test 11: 6-hash heading → PASS ───────────────────────────────────────────
{
    mkdir -p "$TMP_DIR/t11/claude" "$TMP_DIR/t11/pi"
    printf '###### Deep heading\n\nUnique claude content for debug.\n' >"$TMP_DIR/t11/claude/debug.txt"
    printf '###### Deep heading\n\nUnique pi content for debug.\n' >"$TMP_DIR/t11/pi/debug.txt"

    dup_count=0
    while IFS= read -r line; do
        stripped=$(printf '%s' "$line" | tr -d '[:space:]')
        [ -z "$stripped" ] && continue
        printf '%s' "$line" | grep -qE '^[[:space:]]*#{1,6}[[:space:]]' && continue
        [ "${#stripped}" -lt "$MIN_LEN" ] && continue
        dup_count=$((dup_count + 1))
    done < <(comm -12 \
        <(grep -v '^[[:space:]]*$' "$TMP_DIR/t11/claude/debug.txt" | sort) \
        <(grep -v '^[[:space:]]*$' "$TMP_DIR/t11/pi/debug.txt" | sort))

    if [ "$dup_count" -eq 0 ]; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: Test 11 — 6-hash heading is exempt\n'
        pass=$((pass + 1))
    else
        printf 'FAIL: Test 11 — 6-hash heading was flagged (should be exempt)\n'
        fail=$((fail + 1))
    fi
}

# ── Test 12: exactly-8-non-space-char line → FAIL (boundary: >= 8 is NOT exempt) ──
{
    mkdir -p "$TMP_DIR/t12/claude" "$TMP_DIR/t12/pi"
    # "12345678" has exactly 8 non-space chars — at the boundary (NOT exempt)
    printf '## Tools\n\n12345678\nUnique claude line.\n' >"$TMP_DIR/t12/claude/shape.txt"
    printf '## Tools\n\n12345678\nUnique pi line.\n' >"$TMP_DIR/t12/pi/shape.txt"

    dup_count=0
    while IFS= read -r line; do
        stripped=$(printf '%s' "$line" | tr -d '[:space:]')
        [ -z "$stripped" ] && continue
        printf '%s' "$line" | grep -qE '^[[:space:]]*#{1,6}[[:space:]]' && continue
        [ "${#stripped}" -lt "$MIN_LEN" ] && continue
        dup_count=$((dup_count + 1))
    done < <(comm -12 \
        <(grep -v '^[[:space:]]*$' "$TMP_DIR/t12/claude/shape.txt" | sort) \
        <(grep -v '^[[:space:]]*$' "$TMP_DIR/t12/pi/shape.txt" | sort))

    if [ "$dup_count" -gt 0 ]; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: Test 12 — exactly-8-char line IS flagged (boundary: < 8 is exempt, = 8 is not)\n'
        pass=$((pass + 1))
    else
        printf 'FAIL: Test 12 — exactly-8-char line was NOT flagged (should be flagged: >= 8 non-space chars is not exempt)\n'
        fail=$((fail + 1))
    fi
}

# ── Test 13: exit-code assert — detector exits 1 on failures ─────────────────
{
    mkdir -p "$TMP_DIR/t13/claude" "$TMP_DIR/t13/pi"
    printf '## Tools\n\nThis non-trivial sentence appears in both headers identically.\n' \
        >"$TMP_DIR/t13/claude/build.txt"
    printf '## Tools\n\nThis non-trivial sentence appears in both headers identically.\n' \
        >"$TMP_DIR/t13/pi/build.txt"

    rc=0
    (
        set -euo pipefail
        while IFS= read -r line; do
            stripped=$(printf '%s' "$line" | tr -d '[:space:]')
            [ -z "$stripped" ] && continue
            printf '%s' "$line" | grep -qE '^[[:space:]]*#{1,6}[[:space:]]' && continue
            [ "${#stripped}" -lt "$MIN_LEN" ] && continue
            exit 1
        done < <(comm -12 \
            <(grep -v '^[[:space:]]*$' "$TMP_DIR/t13/claude/build.txt" | sort) \
            <(grep -v '^[[:space:]]*$' "$TMP_DIR/t13/pi/build.txt" | sort))
        exit 0
    ) || rc=$?

    if [ "$rc" -eq 1 ]; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: Test 13 — detector exits 1 when duplicate line found\n'
        pass=$((pass + 1))
    else
        printf 'FAIL: Test 13 — detector should exit 1 on duplicate line, got exit %d\n' "$rc"
        fail=$((fail + 1))
    fi
}

# ── Test 14: exit-code assert — detector exits 0 on clean headers ────────────
{
    mkdir -p "$TMP_DIR/t14/claude" "$TMP_DIR/t14/pi"
    printf '## Tools\n\nUnique claude-only line for this test fixture.\n' \
        >"$TMP_DIR/t14/claude/build.txt"
    printf '## Tools\n\nUnique pi-only line for this test fixture.\n' \
        >"$TMP_DIR/t14/pi/build.txt"

    dup_count=0
    while IFS= read -r line; do
        stripped=$(printf '%s' "$line" | tr -d '[:space:]')
        [ -z "$stripped" ] && continue
        printf '%s' "$line" | grep -qE '^[[:space:]]*#{1,6}[[:space:]]' && continue
        [ "${#stripped}" -lt "$MIN_LEN" ] && continue
        dup_count=$((dup_count + 1))
    done < <(comm -12 \
        <(grep -v '^[[:space:]]*$' "$TMP_DIR/t14/claude/build.txt" | sort) \
        <(grep -v '^[[:space:]]*$' "$TMP_DIR/t14/pi/build.txt" | sort))

    if [ "$dup_count" -eq 0 ]; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: Test 14 — clean headers produce exit 0\n'
        pass=$((pass + 1))
    else
        printf 'FAIL: Test 14 — clean headers were incorrectly flagged\n'
        fail=$((fail + 1))
    fi
}

# ── Test 15: multi-pitch markers ABSENT from claude tools-header/build.txt ────
{
    CLAUDE_BUILD_HEADER="$CODEGEN_DIR/harnesses/claude/tools-header/build.txt"
    markers=("Slug resolution" "When the operator names NO slugs" "topological sort" "one session log per pitch")
    t15_fail=0
    for marker in "${markers[@]}"; do
        if grep -qF "$marker" "$CLAUDE_BUILD_HEADER" 2>/dev/null; then
            printf 'FAIL: Test 15 — marker "%s" still present in harnesses/claude/tools-header/build.txt (should have been extracted to shared fragment)\n' "$marker"
            t15_fail=$((t15_fail + 1))
            fail=$((fail + 1))
        fi
    done
    if [ "$t15_fail" -eq 0 ]; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: Test 15 — multi-pitch markers absent from claude tools-header/build.txt\n'
        pass=$((pass + 1))
    fi
}

# ── Test 16: multi-pitch markers ABSENT from pi tools-header/build.txt ────────
{
    PI_BUILD_HEADER="$CODEGEN_DIR/harnesses/pi/tools-header/build.txt"
    markers=("Slug resolution" "When the operator names NO slugs" "topological sort" "one session log per pitch")
    t16_fail=0
    for marker in "${markers[@]}"; do
        if grep -qF "$marker" "$PI_BUILD_HEADER" 2>/dev/null; then
            printf 'FAIL: Test 16 — marker "%s" still present in harnesses/pi/tools-header/build.txt (should have been extracted to shared fragment)\n' "$marker"
            t16_fail=$((t16_fail + 1))
            fail=$((fail + 1))
        fi
    done
    if [ "$t16_fail" -eq 0 ]; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: Test 16 — multi-pitch markers absent from pi tools-header/build.txt\n'
        pass=$((pass + 1))
    fi
}

# ── Test 17: multi-pitch markers PRESENT in shared fragment ───────────────────
{
    SHARED_FRAGMENT="$CODEGEN_DIR/harnesses/shared/prompt-bodies/build-multi-pitch-queue.txt"
    markers=("Slug resolution" "When the operator names NO slugs" "topological sort" "one session log per pitch")
    t17_fail=0
    if [ ! -f "$SHARED_FRAGMENT" ]; then
        printf 'FAIL: Test 17 — shared fragment missing: %s\n' "$SHARED_FRAGMENT"
        t17_fail=$((t17_fail + 1))
        fail=$((fail + 1))
    else
        for marker in "${markers[@]}"; do
            if ! grep -qF "$marker" "$SHARED_FRAGMENT" 2>/dev/null; then
                printf 'FAIL: Test 17 — marker "%s" not found in shared fragment %s\n' "$marker" "$SHARED_FRAGMENT"
                t17_fail=$((t17_fail + 1))
                fail=$((fail + 1))
            fi
        done
    fi
    if [ "$t17_fail" -eq 0 ]; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: Test 17 — all multi-pitch markers present in shared fragment\n'
        pass=$((pass + 1))
    fi
}

# ── Test 18: shared fragment wired as prompt_body[1] in both manifests ─────────
{
    CLAUDE_MANIFEST="$CODEGEN_DIR/harnesses/claude/manifest.yaml"
    PI_MANIFEST="$CODEGEN_DIR/harnesses/pi/manifest.yaml"
    FRAGMENT_PATH="harnesses/shared/prompt-bodies/build-multi-pitch-queue.txt"
    t18_fail=0
    for manifest in "$CLAUDE_MANIFEST" "$PI_MANIFEST"; do
        if ! grep -qF "$FRAGMENT_PATH" "$manifest" 2>/dev/null; then
            printf 'FAIL: Test 18 — shared fragment not wired in %s\n' "$manifest"
            t18_fail=$((t18_fail + 1))
            fail=$((fail + 1))
        fi
    done
    if [ "$t18_fail" -eq 0 ]; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: Test 18 — shared fragment wired in both manifests\n'
        pass=$((pass + 1))
    fi
}

# ── Summary ───────────────────────────────────────────────────────────────────
printf '\n%d passed, %d failed\n' "$pass" "$fail"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
