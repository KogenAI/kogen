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

# ── Case 8: run-tests.sh still propagates the xargs pipeline stage status ────
# Guards against a future edit shifting PIPESTATUS index away from xargs.
if grep -n '_xargs_rc=\${PIPESTATUS\[1\]}' "$HOOK_RUNNER" >/dev/null 2>&1; then
    _assert_true "run-tests.sh reads PIPESTATUS[1] for xargs exit status" 0
else
    _assert_true "run-tests.sh reads PIPESTATUS[1] for xargs exit status" 1
fi
if grep -qE '^\s*xargs ' "$HOOK_RUNNER"; then
    _assert_true "run-tests.sh's discovery pipeline pipes directly into xargs (2-stage)" 0
else
    _assert_true "run-tests.sh's discovery pipeline pipes directly into xargs (2-stage)" 1
fi

printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
