#!/usr/bin/env bash
set -euo pipefail
# run-all-tests_test.sh — assert every discovered harnesses/claude/hooks/*_test.sh
# has exactly one owner in a `make test` run: either the backgrounded hooks arm
# (auto-discovery) or a direct Makefile caller (harness-parity,
# prompt-content-parity, tools-header-no-dup), never both.
#
# STATIC AUDIT ONLY. This test itself runs concurrently with the hooks arm
# under `make test` (discovered via templates/generator/run-tests.sh, invoked
# by the test-generator arm) — it MUST NOT invoke the live hook suite. Cases
# that exercise run-tests.sh's exclusion filtering use throwaway fixture dirs.
#
# Usage: bash run-all-tests_test.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RUN_ALL="$SCRIPT_DIR/run-all-tests.sh"
HOOK_RUNNER="$REPO_ROOT/harnesses/claude/hooks/run-tests.sh"
MAKEFILE="$REPO_ROOT/Makefile"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0

_assert_eq() {
    local label="$1"
    local expected="$2"
    local actual="$3"
    if [ "$actual" = "$expected" ]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        echo "FAIL: $label"
        echo "  expected: $(printf '%q' "$expected")"
        echo "  actual:   $(printf '%q' "$actual")"
    fi
}

_assert_contains() {
    local label="$1"
    local needle="$2"
    local haystack="$3"
    if printf '%s' "$haystack" | grep -qF "$needle"; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        echo "FAIL: $label"
        echo "  expected to contain: $needle"
        echo "  actual: $haystack"
    fi
}

_assert_not_contains() {
    local label="$1"
    local needle="$2"
    local haystack="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        fail=$((fail + 1))
        echo "FAIL: $label"
        echo "  did not expect to find: $needle"
    else
        pass=$((pass + 1))
    fi
}

_assert_true() {
    local label="$1"
    local cond="$2" # "0" for true, non-"0" for false
    if [ "$cond" = "0" ]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        echo "FAIL: $label"
    fi
}

# ── Derive committed state (never hardcode independently of the source) ──────

# HOOK_DEDUP_EXCLUDE literal out of run-all-tests.sh: an awk state-machine
# scoped to the assignment (opens on `HOOK_DEDUP_EXCLUDE="`, closes on the
# first line ending in a bare `"`), so it never runs away to EOF.
declared_exclusions=$(awk '
    /^HOOK_DEDUP_EXCLUDE="/ { in_block=1; sub(/^HOOK_DEDUP_EXCLUDE="/, ""); if ($0 ~ /"$/) { sub(/"$/, ""); print; exit } print; next }
    in_block { if ($0 ~ /"$/) { sub(/"$/, ""); print; exit } print }
' "$RUN_ALL")

# Every direct Makefile caller of a harnesses/claude/hooks/*_test.sh file,
# EXCLUDING the run-all-tests.sh hooks-arm invocation itself (that line
# invokes run-tests.sh, not an individual *_test.sh).
makefile_callers=$(grep -oE 'harnesses/claude/hooks/[A-Za-z0-9_-]+_test\.sh' "$MAKEFILE" | sort -u)

# Full committed hook test population, normalized to repo-relative form.
hook_population=$(find "$REPO_ROOT/harnesses/claude/hooks" -maxdepth 1 -name '*_test.sh' -type f -exec basename {} \; | sed 's#^#harnesses/claude/hooks/#' | sort -u)

# ── Case 1: every declared exclusion exists as a real hook test file ─────────
missing=0
while IFS= read -r p; do
    [ -n "$p" ] || continue
    if [ ! -f "$REPO_ROOT/$p" ]; then
        missing=1
        echo "  missing file for declared exclusion: $p"
    fi
done <<<"$declared_exclusions"
_assert_true "every declared exclusion is a real file" "$missing"

# ── Case 2: every declared exclusion has >=1 direct Makefile caller ──────────
uncalled=0
while IFS= read -r p; do
    [ -n "$p" ] || continue
    if ! printf '%s\n' "$makefile_callers" | grep -qxF "$p"; then
        uncalled=1
        echo "  declared exclusion has no direct Makefile caller: $p"
    fi
done <<<"$declared_exclusions"
_assert_true "every declared exclusion has a direct Makefile caller" "$uncalled"

# ── Case 3: every direct-Makefile-called hook test is declared excluded ──────
# (catches: a new duplicate added to the Makefile without updating ownership)
undeclared=0
while IFS= read -r p; do
    [ -n "$p" ] || continue
    if ! printf '%s\n' "$declared_exclusions" | grep -qxF "$p"; then
        undeclared=1
        echo "  Makefile-called hook test not in HOOK_DEDUP_EXCLUDE: $p"
    fi
done <<<"$makefile_callers"
_assert_true "every direct-called hook test is declared excluded" "$undeclared"

# ── Case 4: no hook test outside the exclusion set has a direct caller ───────
# (inverse of case 3 — multiply-owned detection). Every population member
# appears in makefile_callers XOR is left for auto-discovery (not declared).
# A member cannot be BOTH called AND absent from declared_exclusions (that's
# case 3's job) — case 4 asserts the SET EQUALITY between makefile_callers and
# declared_exclusions directly.
sorted_callers=$(printf '%s\n' "$makefile_callers" | sort -u)
sorted_declared=$(printf '%s\n' "$declared_exclusions" | sort -u)
_assert_eq "declared exclusions equal Makefile-called hook tests (set equality)" "$sorted_declared" "$sorted_callers"

# ── Case 5: run-tests.sh with HOOK_TEST_EXCLUDE unset discovers full pop ─────
FIXTURE_HOOKS="$TMP/hooks-fixture-1"
mkdir -p "$FIXTURE_HOOKS"
for n in alpha beta gamma; do
    cat >"$FIXTURE_HOOKS/${n}_test.sh" <<'EOF'
#!/usr/bin/env bash
echo "1 passed, 0 failed"
exit 0
EOF
    chmod +x "$FIXTURE_HOOKS/${n}_test.sh"
done
_discover_unset() {
    # Mirror run-tests.sh's _discover_hook_tests logic against the fixture dir.
    local f rel
    while IFS= read -r -d '' f; do
        rel="harnesses/claude/hooks/$(basename "$f")"
        if [ -n "${HOOK_TEST_EXCLUDE:-}" ] && printf '%s\n' "$HOOK_TEST_EXCLUDE" | grep -qxF "$rel"; then
            continue
        fi
        printf '%s\n' "$f"
    done < <(find "$FIXTURE_HOOKS" -name '*_test.sh' -type f -print0)
}
unset HOOK_TEST_EXCLUDE
discovered_unset=$(_discover_unset | sort)
expected_unset=$(printf '%s\n' "$FIXTURE_HOOKS/alpha_test.sh" "$FIXTURE_HOOKS/beta_test.sh" "$FIXTURE_HOOKS/gamma_test.sh" | sort)
_assert_eq "unset HOOK_TEST_EXCLUDE discovers full fixture population" "$expected_unset" "$discovered_unset"

# ── Case 6: HOOK_TEST_EXCLUDE naming one fixture stub runs exactly the other two
export HOOK_TEST_EXCLUDE="harnesses/claude/hooks/beta_test.sh"
discovered_excl=$(_discover_unset | sort)
expected_excl=$(printf '%s\n' "$FIXTURE_HOOKS/alpha_test.sh" "$FIXTURE_HOOKS/gamma_test.sh" | sort)
_assert_eq "declared exclusion filters exactly the named fixture" "$expected_excl" "$discovered_excl"
unset HOOK_TEST_EXCLUDE

# ── Case 7: a declared-but-unmatched exclusion path is detectable ────────────
# (proves the case-1/case-2 style checks above would actually catch drift)
bogus_declared="harnesses/claude/hooks/does-not-exist_test.sh"
if [ -f "$REPO_ROOT/$bogus_declared" ]; then
    fail=$((fail + 1))
    echo "FAIL: bogus fixture path unexpectedly exists on disk: $bogus_declared"
else
    pass=$((pass + 1))
fi

# ── Case 8: run-tests.sh still propagates xargs's own exit status ───────────
# Discovery is captured to a NUL-delimited temp file (not piped directly into
# xargs) so an empty-discovery guard can run first — bash `$()` command
# substitution cannot hold embedded NUL bytes, so the guard needs a real file
# to test non-emptiness against. xargs is then fed via `<` redirect (not a
# pipe), so its own $? is read directly — no PIPESTATUS indexing needed.
if grep -qE '_xargs_rc=\$\?' "$HOOK_RUNNER"; then
    _assert_true "run-tests.sh reads xargs's own exit status (\$?)" 0
else
    _assert_true "run-tests.sh reads xargs's own exit status (\$?)" 1
fi
if grep -qE '^\s*xargs .*<"\$_hook_tests_file"' "$HOOK_RUNNER"; then
    _assert_true "run-tests.sh feeds xargs from the NUL-delimited discovery file" 0
else
    _assert_true "run-tests.sh feeds xargs from the NUL-delimited discovery file" 1
fi
if grep -qE '^\s*if \[ ! -s "\$_hook_tests_file" \]; then$' "$HOOK_RUNNER"; then
    _assert_true "run-tests.sh guards empty discovery before invoking xargs" 0
else
    _assert_true "run-tests.sh guards empty discovery before invoking xargs" 1
fi

# ── Case 8b: gate-pending snapshot is NUL-safe and empty-safe ───────────────
# Snapshot discovery cannot pipe directly into xargs: BSD/macOS xargs invokes
# the command once on empty stdin, producing bogus stderr and a fake $0. Keep
# parity with the hook-test discovery runner: capture NUL paths to a temp file,
# guard with -s, then loop one path → one hash.
snapshot_body=$(sed -n '/^_gate_pending_snapshot()/,/^}/p' "$HOOK_RUNNER")
_assert_not_contains "run-tests.sh gate-pending snapshot does not use xargs" "xargs" "$snapshot_body"
_assert_contains "run-tests.sh gate-pending snapshot uses a NUL-delimited temp file" '_gate_pending_paths_file=$(mktemp)' "$snapshot_body"
_assert_contains "run-tests.sh gate-pending snapshot guards empty discovery" 'if [ -s "$_gate_pending_paths_file" ]; then' "$snapshot_body"
_assert_contains "run-tests.sh gate-pending snapshot hashes each NUL path in a loop" "read -r -d '' _gate_pending_path" "$snapshot_body"
_assert_contains "run-tests.sh gate-pending snapshot ignores invocation sentinels" "! -name 'codegen-invocation.*'" "$snapshot_body"
_assert_not_contains "run-tests.sh gate-pending snapshot still checks durable files" "! -name 'gate-result.json'" "$snapshot_body"

# ── Case 9: phase membership — tail labels declared in exactly one branch ────
# Phase 1 is everything between the "Phase 1" marker and the "Phase 2" marker
# (this now INCLUDES the core-gated overlap block, which conditionally
# backgrounds the 3 tail populations into phase 1's own pid/labels/tmps
# arrays); phase 2 is everything after the "Phase 2" marker (the serial
# fallback, gated on TAIL_OVERLAP != 1). Each of the three tail labels must
# appear as a `labels+=(...)` in BOTH regions — once inside phase 1's
# `if [ "$TAIL_OVERLAP" = "1" ]` overlap block, and once inside phase 2's
# `if [ "$TAIL_OVERLAP" != "1" ]` serial block — since exactly one of the two
# conditionals fires at runtime, never both, never neither.
phase1_block=$(awk '/# ── Phase 1:/{p=1} /# ── Phase 2:/{p=0} p' "$RUN_ALL")
phase2_block=$(awk '/# ── Phase 2:/{p=1} p' "$RUN_ALL")
for tail_label in hooks test-hermetic rule-render-freshness; do
    if printf '%s\n' "$phase1_block" | grep -qE "labels\+=\(${tail_label}\)"; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        echo "FAIL: phase membership — '$tail_label' not declared in phase 1's overlap block"
    fi
    if printf '%s\n' "$phase2_block" | grep -qE "labels\+=\(${tail_label}\)"; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        echo "FAIL: phase membership — '$tail_label' not declared in phase 2's serial block"
    fi
done

# ── Case 9b: the phase-1 overlap declaration is actually gated on
# TAIL_OVERLAP, and the phase-2 serial declaration is gated on its negation —
# guards against the two blocks accidentally both running unconditionally
# (which would double-run the 3 tail populations every time).
if printf '%s\n' "$phase1_block" | grep -qE 'if \[ "\$TAIL_OVERLAP" = "1" \]; then'; then
    pass=$((pass + 1))
else
    fail=$((fail + 1))
    echo "FAIL: phase 1 overlap block is not gated on TAIL_OVERLAP=1"
fi
if printf '%s\n' "$phase2_block" | grep -qE 'if \[ "\$TAIL_OVERLAP" != "1" \]; then'; then
    pass=$((pass + 1))
else
    fail=$((fail + 1))
    echo "FAIL: phase 2 serial block is not gated on TAIL_OVERLAP != 1"
fi

# ── Case 10: tail continuation — an early tail failure does not skip later ───
# tail populations. Reproduce the exact if/fail/labels pattern run-all-tests.sh
# uses for its three tail populations, with the first population stubbed to
# fail, and assert all three still execute (each appends to a marker file).
TAIL_MARKER="$TMP/tail-marker"
: >"$TAIL_MARKER"
(
    fail=0
    failed_labels=()
    # population A: fails
    if ! false; then
        fail=1
        failed_labels+=(pop-a)
    fi
    echo "pop-a-ran" >>"$TAIL_MARKER"
    # population B: still runs after A failed
    if ! true; then
        fail=1
        failed_labels+=(pop-b)
    fi
    echo "pop-b-ran" >>"$TAIL_MARKER"
    # population C: still runs after A failed
    if ! true; then
        fail=1
        failed_labels+=(pop-c)
    fi
    echo "pop-c-ran" >>"$TAIL_MARKER"
    exit "$fail"
) || true
tail_ran=$(cat "$TAIL_MARKER")
expected_tail_ran=$'pop-a-ran\npop-b-ran\npop-c-ran'
_assert_eq "tail continuation: all three populations ran despite early failure" "$expected_tail_ran" "$tail_ran"

# ── Case 11: npm leaf continuation — one failing leaf still lets siblings run
# Reproduce the exact npm-ext loop shape (explicit conditional capturing rc,
# not a bare `out=$(...)` that would abort under set -e) with one leaf stubbed
# to fail, and assert every leaf in the loop still executes.
NPM_MARKER="$TMP/npm-marker"
: >"$NPM_MARKER"
(
    set -e
    fail=0
    for ext in leaf-fail leaf-ok-1 leaf-ok-2; do
        echo "$ext-visited" >>"$NPM_MARKER"
        if [ "$ext" = "leaf-fail" ]; then
            if ! out=$(false 2>&1); then
                fail=1
            fi
        else
            if ! out=$(true 2>&1); then
                fail=1
            fi
        fi
    done
    exit "$fail"
) || true
npm_visited=$(cat "$NPM_MARKER")
expected_npm_visited=$'leaf-fail-visited\nleaf-ok-1-visited\nleaf-ok-2-visited'
_assert_eq "npm leaf continuation: every leaf visited despite one failing" "$expected_npm_visited" "$npm_visited"

# ── Case 12: all-failure collection — multiple simultaneous failures all
# appear in failed_labels, mirroring run-all-tests.sh's wait-loop accumulator.
(
    fail=0
    failed_labels=()
    for entry in "a:1" "b:0" "c:1" "d:0"; do
        label="${entry%%:*}"
        rc="${entry##*:}"
        if [ "$rc" != "0" ]; then
            fail=1
            failed_labels+=("$label")
        fi
    done
    printf '%s\n' "${failed_labels[@]}" >"$TMP/all-failure-labels"
    exit "$fail"
) || true
all_failure_labels=$(cat "$TMP/all-failure-labels" | tr '\n' ',' | sed 's/,$//')
_assert_eq "all-failure collection: both failing labels captured" "a,c" "$all_failure_labels"

# ── Case 13: snapshot-command failure → tracked-tree-isolation, never green ──
# Reproduce run-all-tests.sh's entry-snapshot guard: a git command run against
# a nonexistent cwd must exit non-zero and never produce a false-empty snapshot.
if git -C "$TMP/definitely-missing-dir-$$" diff --binary --full-index HEAD -- >"$TMP/snapshot-fail-out" 2>&1; then
    fail=$((fail + 1))
    echo "FAIL: snapshot-command failure — git unexpectedly succeeded against a missing dir"
else
    pass=$((pass + 1))
fi

# ── Case 14: tracked-tree fixtures — clean / pre-dirty / mutated variants ────
# Build a throwaway git repo (never the real codegen checkout) and exercise
# the exact snapshot-compare idiom run-all-tests.sh uses:
#   git diff --binary --full-index HEAD -- (before) vs (after), cmp -s.
FIXTURE_REPO="$TMP/tracked-tree-fixture"
mkdir -p "$FIXTURE_REPO"
(
    cd "$FIXTURE_REPO"
    git init -q
    git config user.email "test@example.com"
    git config user.name "Test"
    printf 'hello\n' >tracked.txt
    printf '#!/bin/sh\necho hi\n' >exec.sh
    chmod +x exec.sh
    ln -s tracked.txt link.txt
    git add -A
    git commit -q -m "initial"
)

_snapshot() { (cd "$FIXTURE_REPO" && git diff --binary --full-index HEAD --); }

# 14a: clean tree — before == after → pass
before=$(_snapshot)
after=$(_snapshot)
_assert_eq "tracked-tree fixture: clean tree snapshots match" "$before" "$after"

# 14b: pre-existing dirty tree, UNCHANGED across the window — before == after → pass
(cd "$FIXTURE_REPO" && printf 'pre-existing-dirty\n' >>tracked.txt)
before_dirty=$(_snapshot)
after_dirty=$(_snapshot)
_assert_eq "tracked-tree fixture: pre-existing dirty tree unchanged across window matches" "$before_dirty" "$after_dirty"
(cd "$FIXTURE_REPO" && git checkout -q -- tracked.txt)

# 14c: binary content mutation — before != after → fail (detected)
before_binary=$(_snapshot)
printf '\x00\x01binary-mutation\x02\x00' >"$FIXTURE_REPO/tracked.txt"
after_binary=$(_snapshot)
if [ "$before_binary" != "$after_binary" ]; then
    pass=$((pass + 1))
else
    fail=$((fail + 1))
    echo "FAIL: tracked-tree fixture: binary content mutation not detected"
fi
(cd "$FIXTURE_REPO" && git checkout -q -- tracked.txt)

# 14d: executable-mode flip — before != after → fail (detected)
before_mode=$(_snapshot)
chmod -x "$FIXTURE_REPO/exec.sh"
after_mode=$(_snapshot)
if [ "$before_mode" != "$after_mode" ]; then
    pass=$((pass + 1))
else
    fail=$((fail + 1))
    echo "FAIL: tracked-tree fixture: executable-mode flip not detected"
fi
(cd "$FIXTURE_REPO" && chmod +x exec.sh)

# 14e: symlink retarget — before != after → fail (detected)
before_symlink=$(_snapshot)
(cd "$FIXTURE_REPO" && rm -f link.txt && ln -s exec.sh link.txt)
after_symlink=$(_snapshot)
if [ "$before_symlink" != "$after_symlink" ]; then
    pass=$((pass + 1))
else
    fail=$((fail + 1))
    echo "FAIL: tracked-tree fixture: symlink retarget not detected"
fi
(cd "$FIXTURE_REPO" && git checkout -q -- link.txt)

# 14f: deletion — before != after → fail (detected)
before_delete=$(_snapshot)
rm -f "$FIXTURE_REPO/tracked.txt"
after_delete=$(_snapshot)
if [ "$before_delete" != "$after_delete" ]; then
    pass=$((pass + 1))
else
    fail=$((fail + 1))
    echo "FAIL: tracked-tree fixture: deletion not detected"
fi
(cd "$FIXTURE_REPO" && git checkout -q -- tracked.txt)

# ── Case 15: untracked-path leak backstop — comm -13 idiom ───────────────────
# Reproduce run-all-tests.sh's untracked-set snapshot-compare:
#   git status --porcelain --untracked-files=all (before) vs (after),
#   comm -13 <(sort before) <(sort after) — non-empty output = leak detected.
_untracked_snapshot() { (cd "$FIXTURE_REPO" && git status --porcelain --untracked-files=all --); }

# 15a: new untracked path created during the window → detected
before_untracked=$(_untracked_snapshot)
printf 'leaked\n' >"$FIXTURE_REPO/leaked-artifact.txt"
after_untracked=$(_untracked_snapshot)
new_untracked=$(comm -13 <(printf '%s\n' "$before_untracked" | sort) <(printf '%s\n' "$after_untracked" | sort))
if [ -n "$new_untracked" ]; then
    pass=$((pass + 1))
else
    fail=$((fail + 1))
    echo "FAIL: untracked-path fixture: new leaked path not detected"
fi
_assert_contains "untracked-path fixture: leaked path named in diff" "leaked-artifact.txt" "$new_untracked"
rm -f "$FIXTURE_REPO/leaked-artifact.txt"

# 15b: pre-existing untracked file, UNCHANGED across the window → tolerated
printf 'pre-existing-scratch\n' >"$FIXTURE_REPO/pre-existing-scratch.txt"
before_persist=$(_untracked_snapshot)
after_persist=$(_untracked_snapshot)
new_persist=$(comm -13 <(printf '%s\n' "$before_persist" | sort) <(printf '%s\n' "$after_persist" | sort))
if [ -z "$new_persist" ]; then
    pass=$((pass + 1))
else
    fail=$((fail + 1))
    echo "FAIL: untracked-path fixture: pre-existing unchanged untracked file wrongly flagged"
fi
rm -f "$FIXTURE_REPO/pre-existing-scratch.txt"

# ── Case 16: overlap threshold validates fail-loud, never falls open ────────
# Source-structure assertion (mirrors Case 13's snapshot-guard style): assert
# BOTH TAIL_OVERLAP_MIN_CORES and the detected core count are range-validated
# (1..1024, non-numeric rejected) BEFORE the `-ge` comparison is made, and
# that a validation failure is an immediate `exit 1` — never a silent
# fall-through to either branch. This is the exact defect the first build's
# reviewer caught: an unchecked `[ "$cores" -ge "$MIN" ]` can error-to-false
# on garbage input and silently pick the serial branch.
if grep -qE '_validate_positive_int_1_1024' "$RUN_ALL"; then
    pass=$((pass + 1))
else
    fail=$((fail + 1))
    echo "FAIL: run-all-tests.sh has no range-validation helper for the overlap threshold"
fi
if grep -qE '_validate_positive_int_1_1024 "TAIL_OVERLAP_MIN_CORES"' "$RUN_ALL"; then
    pass=$((pass + 1))
else
    fail=$((fail + 1))
    echo "FAIL: TAIL_OVERLAP_MIN_CORES is not passed through the range-validation helper"
fi
if grep -qE '_validate_positive_int_1_1024 "detected core count"' "$RUN_ALL"; then
    pass=$((pass + 1))
else
    fail=$((fail + 1))
    echo "FAIL: detected core count is not passed through the range-validation helper"
fi
# The validation calls must appear TEXTUALLY BEFORE the `-ge` branch decision.
validate_line=$(grep -n '_validate_positive_int_1_1024 "detected core count"' "$RUN_ALL" | head -1 | cut -d: -f1)
branch_line=$(grep -n 'if \[ "\$cores" -ge "\$TAIL_OVERLAP_MIN_CORES" \]; then' "$RUN_ALL" | head -1 | cut -d: -f1)
if [ -n "$validate_line" ] && [ -n "$branch_line" ] && [ "$validate_line" -lt "$branch_line" ]; then
    pass=$((pass + 1))
else
    fail=$((fail + 1))
    echo "FAIL: core-count validation does not run before the TAIL_OVERLAP branch decision"
fi
# Exercise the actual validation function in isolation (source only the
# function body via a subshell — never invoke the full suite here).
_extract_validator() {
    awk '/^_validate_positive_int_1_1024\(\)/{p=1} p{print} p && /^}/{exit}' "$RUN_ALL"
}
validator_src=$(_extract_validator)
if [ -z "$validator_src" ]; then
    fail=$((fail + 1))
    echo "FAIL: could not extract _validate_positive_int_1_1024 from run-all-tests.sh"
else
    # Garbage (non-numeric) input must exit 1 with a named stderr message.
    rc_garbage=0
    out_garbage=$(bash -c "$validator_src"$'\n''_validate_positive_int_1_1024 "TAIL_OVERLAP_MIN_CORES" "abc"' 2>&1) || rc_garbage=$?
    _assert_true "garbage TAIL_OVERLAP_MIN_CORES exits non-zero" "$([ "$rc_garbage" -ne 0 ]; echo $?)"
    _assert_contains "garbage TAIL_OVERLAP_MIN_CORES names the problem" "TAIL_OVERLAP_MIN_CORES" "$out_garbage"

    # Empty input must exit 1.
    rc_empty=0
    bash -c "$validator_src"$'\n''_validate_positive_int_1_1024 "detected core count" ""' >/dev/null 2>&1 || rc_empty=$?
    _assert_true "empty core-count probe exits non-zero" "$([ "$rc_empty" -ne 0 ]; echo $?)"

    # Oversized (out-of-range) input must exit 1.
    rc_oversized=0
    bash -c "$validator_src"$'\n''_validate_positive_int_1_1024 "TAIL_OVERLAP_MIN_CORES" "99999"' >/dev/null 2>&1 || rc_oversized=$?
    _assert_true "oversized TAIL_OVERLAP_MIN_CORES (99999) exits non-zero" "$([ "$rc_oversized" -ne 0 ]; echo $?)"

    # A valid in-range value must NOT exit non-zero (no false-positive reject).
    rc_valid=0
    bash -c "$validator_src"$'\n''_validate_positive_int_1_1024 "TAIL_OVERLAP_MIN_CORES" "6"' >/dev/null 2>&1 || rc_valid=$?
    _assert_true "valid TAIL_OVERLAP_MIN_CORES (6) does not exit non-zero" "$rc_valid"
fi

# ── Case 17: full-population harness-parity remains one P8 pool ─────────────
harness_parity_recipe=$(awk '/^harness-parity:/{p=1;next} p{if ($0 !~ /^\t/){exit} print}' "$MAKEFILE")
_assert_contains "harness-parity uses NUL-delimited xargs P8" "xargs -0 -n1 -P8" "$harness_parity_recipe"
_assert_contains "harness-parity guards empty input before xargs" '[ ! -s "$$t_in" ]' "$harness_parity_recipe"
_assert_contains "harness-parity propagates xargs infrastructure rc" "xargs_rc" "$harness_parity_recipe"
_assert_not_contains "harness-parity has no serial-only partition" "HARNESS_PARITY_SERIAL_ONLY" "$(cat "$MAKEFILE")"
_assert_not_contains "run-all-tests has no timing-sensitive barrier target" "harness-parity-timing-sensitive" "$(cat "$RUN_ALL")"

declared_hardcoded=$(printf '%s\n' "$harness_parity_recipe" | grep -oE '"\$\(SCRIPT_DIR\)/[A-Za-z0-9_./-]+_test\.sh"' | tr -d '"' | xargs -n1 basename 2>/dev/null | sort -u)
shared_glob_files=$(cd "$REPO_ROOT" && for f in harnesses/shared/*_test.sh; do [ -e "$f" ] && basename "$f"; done | sort -u)
full_population=$(printf '%s\n%s\n' "$declared_hardcoded" "$shared_glob_files" | sed '/^$/d' | sort -u)
full_raw_count=$(printf '%s\n%s\n' "$declared_hardcoded" "$shared_glob_files" | sed '/^$/d' | wc -l | tr -d ' ')
full_unique_count=$(printf '%s\n' "$full_population" | wc -l | tr -d ' ')
_assert_eq "harness-parity full population has no duplicate basename ownership" "$full_unique_count" "$full_raw_count"
_assert_contains "harness-parity full population includes loop-signal-bridge_test.sh" "loop-signal-bridge_test.sh" "$full_population"
_assert_contains "harness-parity full population includes pitch-postflight_test.sh" "pitch-postflight_test.sh" "$full_population"

# ── Case 18: real scheduler executes full parity population exactly once ────
_case18_build_fixture() {
    local fixture="$1" order_log="$2"
    local active_dir="$3" parity_full_file="$4"
    mkdir -p "$fixture/templates/generator" "$fixture/bin" "$active_dir"
    cp "$RUN_ALL" "$fixture/templates/generator/run-all-tests.sh"
    chmod +x "$fixture/templates/generator/run-all-tests.sh"

    # Stub the three ./<path>/run-tests.sh-style direct invocations
    # run-all-tests.sh calls with a relative path (not through `make`). Each
    # records the SAME label run-all-tests.sh itself uses for that stage
    # (scaffold-phoenix / install / hooks) — not bare basename, since all
    # three scripts are literally named run-tests.sh and basename alone would
    # collide into one indistinguishable marker.
    mkdir -p "$fixture/shared/scaffold/phoenix" "$fixture/test_harness/install" "$fixture/harnesses/claude/hooks"
    # Portable parallel-array mapping (bash 3.2 on macOS has no associative
    # arrays) — index-aligned rel path -> marker name.
    _rel_paths=(shared/scaffold/phoenix/run-tests.sh test_harness/install/run-tests.sh harnesses/claude/hooks/run-tests.sh)
    _rel_labels=(scaffold-phoenix install hooks)
    for _i in "${!_rel_paths[@]}"; do
        rel="${_rel_paths[$_i]}"
        marker_name="${_rel_labels[$_i]}"
        cat >"$fixture/$rel" <<EOF
#!/usr/bin/env bash
"$fixture/bin/_order_log_marker.sh" "$marker_name"
exit 0
EOF
        chmod +x "$fixture/$rel"
    done

    # Shared order-log marker helper: mkdir-based spinlock (portable — no
    # flock on macOS/BSD) so concurrent stub invocations never interleave a
    # partial line into the shared order log. mkdir is atomic on POSIX
    # filesystems. The order log lives OUTSIDE the fixture git repo entirely
    # (a sibling path, never `git add`-ed) — placing it inside the repo would
    # make the real script's own tracked-tree isolation backstop correctly
    # flag every marker write as a suite-caused mutation, failing the run for
    # a reason that has nothing to do with the scheduling behavior under test.
    cat >"$fixture/bin/_order_log_marker.sh" <<EOF
#!/usr/bin/env bash
order_log="$order_log"
active_dir="$active_dir"
label="\$1"
marker_pid="\$\$"
own_active="\$active_dir/\$label.\$marker_pid"
lockdir="\$order_log.lockdir"
seq_file="\$order_log.seq"
while ! mkdir "\$lockdir" 2>/dev/null; do
    sleep 0.01
done
seq=0
[ -f "\$seq_file" ] && seq=\$(sed -n '1p' "\$seq_file")
seq=\$((seq + 1))
printf '%s\n' "\$seq" >"\$seq_file"
active_before=\$(find "\$active_dir" -maxdepth 1 -type f -print 2>/dev/null | wc -l | tr -d ' ')
active_names=\$(find "\$active_dir" -maxdepth 1 -type f -exec basename {} \\; 2>/dev/null | sort | tr '\n' ',' | sed 's/,\$//')
printf '%s %s %s %s %s\n' "\$seq" "\$label" "\$marker_pid" "\$active_before" "\${active_names:-none}" >>"\$order_log"
printf '%s\n' "\$label" >"\$own_active"
rmdir "\$lockdir"
case "\$label" in
    parity:*) ;;
    *) sleep 0.2 ;;
esac
rm -f "\$own_active"
EOF
    chmod +x "$fixture/bin/_order_log_marker.sh"

    # `make` recorder stub on PATH: records the target name and, for
    # harness-parity, records every real parity basename owned by the single
    # production P8 aggregate.
    cat >"$fixture/bin/make" <<EOF
#!/usr/bin/env bash
target=""
for a in "\$@"; do
    case "\$a" in
        --no-print-directory) ;;
        *) target="\$a" ;;
    esac
done
"$fixture/bin/_order_log_marker.sh" "\$target"
case "\$target" in
    harness-parity)
        while IFS= read -r name; do
            [ -n "\$name" ] || continue
            "$fixture/bin/_order_log_marker.sh" "parity:\$name"
        done <"$parity_full_file"
        ;;
esac
exit 0
EOF
    chmod +x "$fixture/bin/make"

    : >"$order_log"

    # Throwaway git-init'd repo so the real git diff/status backstop calls in
    # run-all-tests.sh succeed (never stubbed — exercises the real code
    # path). The order log is NOT part of this tree (see above), so the
    # fixture repo stays byte-identical across the run and the real
    # tracked/untracked-tree isolation backstop legitimately passes.
    (
        cd "$fixture" &&
            git init -q &&
            git config user.email "case19@example.com" &&
            git config user.name "case19" &&
            git add -A &&
            git commit -q -m "case19 fixture baseline"
    ) >/dev/null 2>&1
}

_run_case18_branch() {
    local branch_label="$1" tail_overlap_min_cores="$2"
    local fixture="$TMP/case18-fixture-$branch_label"
    local order_log="$TMP/case18-order-$branch_label.log"
    local active_dir="$TMP/case18-active-$branch_label"
    local parity_full_file="$TMP/case18-parity-full-$branch_label.txt"
    rm -rf "$fixture"
    mkdir -p "$fixture"

    printf '%s\n' "$full_population" | sed '/^$/d' | sort >"$parity_full_file"

    _case18_build_fixture "$fixture" "$order_log" "$active_dir" "$parity_full_file"

    local run_out
    run_out=$(cd "$fixture" && PATH="$fixture/bin:$PATH" TAIL_OVERLAP_MIN_CORES="$tail_overlap_min_cores" bash templates/generator/run-all-tests.sh 2>&1)
    local run_rc=$?

    _assert_true "case18 [$branch_label]: real run-all-tests.sh exits 0 against the hermetic fixture" "$run_rc"
    _assert_contains "case18 [$branch_label]: real run-all-tests.sh reports ALL CLEAR" "ALL CLEAR" "$run_out"

    # Expected population: every phase-1 label the real script backgrounds,
    # plus the tail pool (hooks/test-hermetic/rule-render-freshness), which
    # runs in phase 1 on overlap and after phase 1 on forced serial.
    local expected_names=(scaffold-phoenix install hook-parity hook-header-parity harness-parity test-generator enforce-registry-parity enforce-hook-rationale prompt-content-parity tools-header-no-dup usage-rules-index-parity prompt-size-budget pitch-scope-parity hooks test-hermetic rule-render-freshness)

    # Assertion 1: every expected name appears EXACTLY ONCE in the real
    # script's own recorded order log (no dup, no omission) — derived from
    # the real scheduler's actual calls, not a hand-modeled list.
    local missing=0 dup=0
    for name in "${expected_names[@]}"; do
        local cnt
        cnt=$(awk -v n="$name" '$2==n' "$order_log" | grep -c . || true)
        if [ "$cnt" -eq 0 ]; then
            missing=1
            echo "  case18 [$branch_label]: expected population never recorded: $name"
        elif [ "$cnt" -gt 1 ]; then
            dup=1
            echo "  case18 [$branch_label]: population recorded more than once: $name ($cnt times)"
        fi
    done
    _assert_true "case18 [$branch_label]: every expected population recorded (no omission, from real scheduler)" "$missing"
    _assert_true "case18 [$branch_label]: no expected population recorded more than once (no dup, from real scheduler)" "$dup"

    # Assertion 1b: every REAL harness-parity basename (raw and unique) is
    # owned exactly once by the real scheduler's public harness-parity target.
    local parity_log_file="$TMP/case18-parity-log-$branch_label.txt"
    awk '$2 ~ /^parity:/ { sub(/^parity:/, "", $2); print $2 }' "$order_log" | sort >"$parity_log_file"
    local parity_raw_count parity_unique_count parity_expected_count
    parity_raw_count=$(wc -l <"$parity_log_file" | tr -d ' ')
    parity_unique_count=$(sort -u "$parity_log_file" | wc -l | tr -d ' ')
    parity_expected_count=$(wc -l <"$parity_full_file" | tr -d ' ')
    _assert_eq "case18 [$branch_label]: raw real parity basename count matches the full population" "$parity_expected_count" "$parity_raw_count"
    _assert_eq "case18 [$branch_label]: unique real parity basename count matches the full population" "$parity_expected_count" "$parity_unique_count"
    _assert_eq "case18 [$branch_label]: real parity basename set equals the full population" "$(cat "$parity_full_file")" "$(sort -u "$parity_log_file")"

    local harness_ts
    harness_ts=$(awk '$2=="harness-parity"{print $1}' "$order_log")
    local tail_pool=(hooks test-hermetic rule-render-freshness)
    local placement_bad=0
    for name in "${tail_pool[@]}"; do
        local name_ts
        name_ts=$(awk -v n="$name" '$2==n{print $1}' "$order_log")
        if [ -z "$name_ts" ] || [ -z "$harness_ts" ]; then
            placement_bad=1
            continue
        fi
        if [ "$branch_label" = "overlap" ]; then
            [ "$name_ts" -gt 0 ] || placement_bad=1
        else
            [ "$name_ts" -gt "$harness_ts" ] || placement_bad=1
        fi
    done
    _assert_true "case18 [$branch_label]: tail pool placement matches forced branch" "$placement_bad"

    local max_active
    max_active=$(awk 'BEGIN{m=0} $4 ~ /^[0-9]+$/ && $4>m {m=$4} END{print m}' "$order_log")
    _assert_true "case18 [$branch_label]: hermetic active markers observed concurrent scheduler stress" "$([ "${max_active:-0}" -gt 0 ]; echo $?)"
}

_run_case18_branch "overlap" "1"
_run_case18_branch "serial" "1024"

printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
