#!/bin/bash
# context-index-parity-scan_test.sh — unit tests for context-index-parity-scan.sh
#
# Tests:
#   1: ADD context/new.md, no row → exit 1 + violation
#   2: ADD context/new.md with row → exit 0
#   3: DELETE context/existing.md with stale row still present → exit 1
#   4: DELETE context/existing.md with row also removed → exit 0
#   5: phantom ref in index (row references non-existent file) → exit 1
#   6: no context change → exit 0
#   7: outside a git repo → exit 0 (fail-open)
#   8: unborn branch (no HEAD commit) → exit 0 (fail-open)
#   9: user-app layout (codegen/PROJECT_CONTEXT.md) ADD with row → exit 0

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCAN="$SCRIPT_DIR/context-index-parity-scan.sh"

pass=0
fail=0

FIXTURES=()
cleanup() {
    for d in "${FIXTURES[@]:-}"; do
        rm -rf "$d"
    done
}
trap cleanup EXIT

# init_fixture <n> — create a fresh git repo with an initial commit.
init_fixture() {
    local n="$1"
    local dir="/tmp/idx-parity-scan-test-${n}"
    rm -rf "$dir"
    mkdir -p "$dir/context"
    (cd "$dir" && git init -q)
    FIXTURES+=("$dir")
    printf '%s' "$dir"
}

commit_all() {
    local dir="$1"
    local msg="$2"
    (cd "$dir" && git -c user.email=a@a -c user.name=a add -A && git -c user.email=a@a -c user.name=a commit -q -m "$msg")
}

run_test() {
    local desc="$1"
    local expected_rc="$2"
    local dir="$3"

    local out rc
    out=$(bash "$SCAN" "$dir" 2>/dev/null) && rc=0 || rc=$?

    if [ "$rc" = "$expected_rc" ]; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s — expected exit %s, got %s\n  out: %s\n' "$desc" "$expected_rc" "$rc" "$out"
        fail=$((fail + 1))
    fi
}

# ---------------------------------------------------------------------------
# Test 1: ADD context/new.md, no row → exit 1
# ---------------------------------------------------------------------------
dir1=$(init_fixture 1)
printf '# doc\n' >"$dir1/PROJECT_CONTEXT.md"
commit_all "$dir1" init
printf 'new stuff\n' >"$dir1/context/new.md"

run_test "ADD context/new.md, no row → exit 1" "1" "$dir1"

# ---------------------------------------------------------------------------
# Test 2: ADD context/new.md with row → exit 0
# ---------------------------------------------------------------------------
dir2=$(init_fixture 2)
printf '# doc\n' >"$dir2/PROJECT_CONTEXT.md"
commit_all "$dir2" init
printf 'new stuff\n' >"$dir2/context/new.md"
printf '`context/new.md`\n' >>"$dir2/PROJECT_CONTEXT.md"

run_test "ADD context/new.md with row → exit 0" "0" "$dir2"

# ---------------------------------------------------------------------------
# Test 3: DELETE context/existing.md with stale row still present → exit 1
# ---------------------------------------------------------------------------
dir3=$(init_fixture 3)
printf '# doc\n`context/existing.md`\n' >"$dir3/PROJECT_CONTEXT.md"
printf 'x\n' >"$dir3/context/existing.md"
commit_all "$dir3" init
rm "$dir3/context/existing.md"

run_test "DELETE context/existing.md, stale row present → exit 1" "1" "$dir3"

# ---------------------------------------------------------------------------
# Test 4: DELETE context/existing.md with row also removed → exit 0
# ---------------------------------------------------------------------------
dir4=$(init_fixture 4)
printf '# doc\n`context/existing.md`\n' >"$dir4/PROJECT_CONTEXT.md"
printf 'x\n' >"$dir4/context/existing.md"
commit_all "$dir4" init
rm "$dir4/context/existing.md"
grep -v existing "$dir4/PROJECT_CONTEXT.md" >"$dir4/PROJECT_CONTEXT.md.tmp" && mv "$dir4/PROJECT_CONTEXT.md.tmp" "$dir4/PROJECT_CONTEXT.md"

run_test "DELETE context/existing.md, row also removed → exit 0" "0" "$dir4"

# ---------------------------------------------------------------------------
# Test 5: phantom ref in index → exit 1
# ---------------------------------------------------------------------------
dir5=$(init_fixture 5)
printf '# doc\n' >"$dir5/PROJECT_CONTEXT.md"
commit_all "$dir5" init
printf '`context/ghost.md`\n' >>"$dir5/PROJECT_CONTEXT.md"

run_test "phantom ref in index → exit 1" "1" "$dir5"

# ---------------------------------------------------------------------------
# Test 6: no context change → exit 0
# ---------------------------------------------------------------------------
dir6=$(init_fixture 6)
printf '# doc\n' >"$dir6/PROJECT_CONTEXT.md"
commit_all "$dir6" init

run_test "no context change → exit 0" "0" "$dir6"

# ---------------------------------------------------------------------------
# Test 7: outside a git repo → exit 0 (fail-open)
# ---------------------------------------------------------------------------
dir7="/tmp/idx-parity-scan-test-7-nogit"
rm -rf "$dir7"
mkdir -p "$dir7/context"
FIXTURES+=("$dir7")
printf '# doc\n' >"$dir7/PROJECT_CONTEXT.md"

run_test "outside a git repo → exit 0 (fail-open)" "0" "$dir7"

# ---------------------------------------------------------------------------
# Test 8: unborn branch (no HEAD commit) → exit 0 (fail-open)
# ---------------------------------------------------------------------------
dir8="/tmp/idx-parity-scan-test-8-unborn"
rm -rf "$dir8"
mkdir -p "$dir8/context"
(cd "$dir8" && git init -q)
FIXTURES+=("$dir8")
printf '# doc\n' >"$dir8/PROJECT_CONTEXT.md"
printf 'x\n' >"$dir8/context/new.md"

run_test "unborn branch → exit 0 (fail-open)" "0" "$dir8"

# ---------------------------------------------------------------------------
# Test 9: user-app layout (codegen/PROJECT_CONTEXT.md) ADD with row → exit 0
# ---------------------------------------------------------------------------
dir9=$(init_fixture 9)
mkdir -p "$dir9/codegen"
printf '# doc\n' >"$dir9/codegen/PROJECT_CONTEXT.md"
commit_all "$dir9" init
printf 'new stuff\n' >"$dir9/context/new.md"
printf '`context/new.md`\n' >>"$dir9/codegen/PROJECT_CONTEXT.md"

run_test "user-app layout ADD with row → exit 0" "0" "$dir9"

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
