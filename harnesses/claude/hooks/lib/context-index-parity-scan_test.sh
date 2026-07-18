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
#  10: root layout, on-disk context/x.md with row but missing Trigger Keywords → exit 1
#  11: root layout, keyword drift (file kw != index cell) → exit 1
#  12: root layout, non-.md clutter in context/ → exit 1
#  13: root layout, PRE-EXISTING (committed, no working-tree delta) context/x.md
#      with no row → exit 1 (full-tree pass catches what the delta pass misses)
#  14: user-app layout (codegen/PROJECT_CONTEXT.md), pre-existing orphan with no
#      delta → exit 0 (full-tree/keyword strict passes stay root-layout-only)
#  15: root layout WITHOUT codegen sentinel (downstream app), pre-existing
#      orphan → exit 0 (full-tree pass must not fire outside codegen self-build)
#  16: root layout WITH codegen sentinel, pre-existing orphan → exit 1
#      (boundary confirmed: full-tree pass still fires for codegen self-build)
#  17: root layout, keywords match exactly → exit 0, no drift message
#  18: root layout, file kw superset of index kw → exit 1, empty-side sentinel

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

# add_codegen_sentinel <dir> — mark a fixture as a codegen self-build repo so
# the full-tree pass (root layout + sentinel) is exercised.
add_codegen_sentinel() {
    local dir="$1"
    mkdir -p "$dir/harnesses/claude"
    printf 'name: claude\n' >"$dir/harnesses/claude/manifest.yaml"
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

# run_test_msg <desc> <dir> <expect_present|expect_absent> <needle> — asserts
# the scan's stdout does/does not contain a substring (message-content check,
# distinct from run_test's exit-code-only assertion).
run_test_msg() {
    local desc="$1"
    local dir="$2"
    local mode="$3"
    local needle="$4"

    local out
    out=$(bash "$SCAN" "$dir" 2>/dev/null) || true

    case "$mode" in
        expect_present)
            if printf '%s' "$out" | grep -qF "$needle"; then
                [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
                pass=$((pass + 1))
            else
                printf 'FAIL: %s — expected output to contain %q\n  out: %s\n' "$desc" "$needle" "$out"
                fail=$((fail + 1))
            fi
            ;;
        expect_absent)
            if printf '%s' "$out" | grep -qF "$needle"; then
                printf 'FAIL: %s — expected output to NOT contain %q\n  out: %s\n' "$desc" "$needle" "$out"
                fail=$((fail + 1))
            else
                [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
                pass=$((pass + 1))
            fi
            ;;
    esac
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
printf '# New\n\n## Trigger Keywords\n\nfoo, bar\n' >"$dir2/context/new.md"
printf '`context/new.md` | always | never | foo, bar\n' >>"$dir2/PROJECT_CONTEXT.md"

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

# ---------------------------------------------------------------------------
# Test 10: root layout, on-disk context/x.md with row but missing Trigger
# Keywords section → exit 1 (full-tree pass, committed so no working-tree delta)
# ---------------------------------------------------------------------------
dir10=$(init_fixture 10)
add_codegen_sentinel "$dir10"
printf '# doc\n\n`context/x.md` | always | never | foo, bar\n' >"$dir10/PROJECT_CONTEXT.md"
printf '# X\n\nsome content, no keywords section\n' >"$dir10/context/x.md"
commit_all "$dir10" init

run_test "root layout, pre-existing file missing Trigger Keywords → exit 1" "1" "$dir10"

# ---------------------------------------------------------------------------
# Test 11: root layout, keyword drift (file kw != index cell) → exit 1
# ---------------------------------------------------------------------------
dir11=$(init_fixture 11)
add_codegen_sentinel "$dir11"
printf '# doc\n\n| `context/x.md` | Desc | foo, bar | never |\n' >"$dir11/PROJECT_CONTEXT.md"
printf '# X\n\n## Trigger Keywords\n\nfoo, baz\n' >"$dir11/context/x.md"
commit_all "$dir11" init

run_test "root layout, keyword drift → exit 1" "1" "$dir11"
run_test_msg "root layout, keyword drift message names file-only token" "$dir11" expect_present "in file only: baz"
run_test_msg "root layout, keyword drift message names index-only token" "$dir11" expect_present "in index only: bar"

# ---------------------------------------------------------------------------
# Test 17: root layout, keywords match exactly → exit 0, no drift message
# ---------------------------------------------------------------------------
dir17=$(init_fixture 17)
add_codegen_sentinel "$dir17"
printf '# doc\n\n| `context/x.md` | Desc | foo, bar | never |\n' >"$dir17/PROJECT_CONTEXT.md"
printf '# X\n\n## Trigger Keywords\n\nfoo, bar\n' >"$dir17/context/x.md"
commit_all "$dir17" init

run_test "root layout, matching keywords → exit 0" "0" "$dir17"
run_test_msg "root layout, matching keywords → no drift message" "$dir17" expect_absent "keyword drift"

# ---------------------------------------------------------------------------
# Test 18: root layout, file keywords are a strict superset of index keywords
# → drift message's index-only side renders the empty sentinel, not a bare
# trailing separator.
# ---------------------------------------------------------------------------
dir18=$(init_fixture 18)
add_codegen_sentinel "$dir18"
printf '# doc\n\n| `context/x.md` | Desc | foo | never |\n' >"$dir18/PROJECT_CONTEXT.md"
printf '# X\n\n## Trigger Keywords\n\nfoo, bar\n' >"$dir18/context/x.md"
commit_all "$dir18" init

run_test "root layout, file superset of index → exit 1" "1" "$dir18"
run_test_msg "root layout, file superset → file-only names extra token" "$dir18" expect_present "in file only: bar"
run_test_msg "root layout, file superset → index-only renders empty sentinel" "$dir18" expect_present "in index only: (none)"

# ---------------------------------------------------------------------------
# Test 12: root layout, non-.md clutter in context/ → exit 1
# ---------------------------------------------------------------------------
dir12=$(init_fixture 12)
add_codegen_sentinel "$dir12"
printf '# doc\n' >"$dir12/PROJECT_CONTEXT.md"
printf 'junk\n' >"$dir12/context/.DS_Store"
commit_all "$dir12" init

run_test "root layout, non-.md clutter in context/ → exit 1" "1" "$dir12"

# ---------------------------------------------------------------------------
# Test 13: root layout, PRE-EXISTING context/x.md (committed, no working-tree
# delta) missing from the Domain table → exit 1 — this is the build-12 case
# the delta pass misses (full-tree pass must catch it).
# ---------------------------------------------------------------------------
dir13=$(init_fixture 13)
add_codegen_sentinel "$dir13"
printf '# doc\n' >"$dir13/PROJECT_CONTEXT.md"
printf '# X\n\n## Trigger Keywords\n\nfoo, bar\n' >"$dir13/context/x.md"
commit_all "$dir13" init

run_test "root layout, pre-existing orphan (no delta) → exit 1" "1" "$dir13"

# ---------------------------------------------------------------------------
# Test 14: user-app layout (codegen/PROJECT_CONTEXT.md), pre-existing orphan
# with no working-tree delta → exit 0 (strict full-tree pass is root-only)
# ---------------------------------------------------------------------------
dir14=$(init_fixture 14)
mkdir -p "$dir14/codegen"
printf '# doc\n' >"$dir14/codegen/PROJECT_CONTEXT.md"
printf '# X\n\nno keywords, no row\n' >"$dir14/context/x.md"
commit_all "$dir14" init

run_test "user-app layout, pre-existing orphan (no delta) → exit 0" "0" "$dir14"

# ---------------------------------------------------------------------------
# Test 15: root layout WITHOUT the codegen sentinel (downstream app carries
# its own root PROJECT_CONTEXT.md, no harnesses/claude/manifest.yaml) →
# full-tree pass must NOT fire even though a pre-existing orphan is present.
# ---------------------------------------------------------------------------
dir15=$(init_fixture 15)
printf '# doc\n' >"$dir15/PROJECT_CONTEXT.md"
printf '# X\n\nno keywords, no row\n' >"$dir15/context/x.md"
commit_all "$dir15" init

run_test "root layout, no codegen sentinel, pre-existing orphan → exit 0" "0" "$dir15"

# ---------------------------------------------------------------------------
# Test 16: root layout WITH the codegen sentinel → full-tree pass still
# fires on a pre-existing orphan (boundary confirmed both directions).
# ---------------------------------------------------------------------------
dir16=$(init_fixture 16)
add_codegen_sentinel "$dir16"
printf '# doc\n' >"$dir16/PROJECT_CONTEXT.md"
printf '# X\n\nno keywords, no row\n' >"$dir16/context/x.md"
commit_all "$dir16" init

run_test "root layout, codegen sentinel present, pre-existing orphan → exit 1" "1" "$dir16"

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
