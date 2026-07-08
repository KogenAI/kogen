#!/usr/bin/env bash
# build-launcher-wrapper_test.sh — hermetic tests for claude-build.sh + pi-build.sh
# wrapper logic (CODEGEN_DIR resolution, --queue dispatch, basename resolver,
# cwd normalization).
#
# CRITICAL INVARIANT: no test case may ever reach a real exec of
# `codegen-build`, `mix codegen.loop*`, `claude`, or `pi`. Every case stubs
# the terminal exec target(s) it can reach and asserts the stub's capture
# file was written (absent capture file ⇒ real binary ran ⇒ FAIL loud).
# run-tests.sh unsets OCG_CODEGEN_DIR before discovery, so every case pins it
# explicitly (or copies the launcher into a synthetic SCRIPT_DIR layout for
# the two non-override CODEGEN_DIR branches).
#
# Both launchers are ~identical; three divergences: pi exports PI_ROLE=build;
# pi emits bare `codegen/pitches/ready/<slug>.md` mentions (claude prefixes
# `@`); message prefixes `pi-build:` vs `claude-build:`.

set -euo pipefail

HOOKS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODEGEN_ROOT="$(cd "$HOOKS_DIR/../../.." && pwd)"
CLAUDE_LAUNCHER="$CODEGEN_ROOT/harnesses/claude/claude-build.sh"
PI_LAUNCHER="$CODEGEN_ROOT/harnesses/pi/pi-build.sh"

pass=0
fail=0

check() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s — expected %q, got %q\n' "$desc" "$expected" "$actual"
        fail=$((fail + 1))
    fi
}

assert_contains() {
    local desc="$1" haystack="$2" needle="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s — expected to find %q\n  got: %s\n' "$desc" "$needle" "${haystack:0:300}"
        fail=$((fail + 1))
    fi
}

assert_not_contains() {
    local desc="$1" haystack="$2" needle="$3"
    if [[ "$haystack" != *"$needle"* ]]; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s — did NOT expect to find %q\n  got: %s\n' "$desc" "$needle" "${haystack:0:300}"
        fail=$((fail + 1))
    fi
}

# assert_capture_exists <desc> <path> — the INVARIANT guard. Absent capture
# file means the real binary was reached instead of the stub.
assert_capture_exists() {
    local desc="$1" path="$2"
    if [[ -f "$path" ]]; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s — capture file missing at %s (real binary may have run!)\n' "$desc" "$path"
        fail=$((fail + 1))
    fi
}

BASE_TMP="$(mktemp -d)"
cleanup() { rm -rf "$BASE_TMP"; }
trap cleanup EXIT

make_stub() {
    local path="$1" body="$2"
    mkdir -p "$(dirname "$path")"
    printf '#!/usr/bin/env bash\n%s\n' "$body" >"$path"
    chmod +x "$path"
}

# make_ws <name> — a workspace dir with its own codegen-build stub (echoes
# argv to $WS/cb_capture.txt) at $WS, used as OCG_CODEGEN_DIR.
make_ws() {
    local name="$1"
    local ws="$BASE_TMP/$name"
    mkdir -p "$ws"
    make_stub "$ws/codegen-build" 'printf '"'"'%s\n'"'"' "$@" > "'"$ws"'/cb_capture.txt"'
    echo "$ws"
}

# make_mix_stub_dir <name> — PATH dir with a `mix` stub echoing argv to
# $dir/mix_capture.txt.
make_mix_stub_dir() {
    local name="$1"
    local dir="$BASE_TMP/$name"
    mkdir -p "$dir"
    make_stub "$dir/mix" 'printf '"'"'%s\n'"'"' "$@" > "'"$dir"'/mix_capture.txt"'
    echo "$dir"
}

# ─────────────────────────────────────────────────────────────────────────
# Parameterized runner: iterate both launchers.
#   $1 = launcher path, $2 = harness label (claude|pi), $3 = msg prefix
# ─────────────────────────────────────────────────────────────────────────
LAUNCHERS=("$CLAUDE_LAUNCHER:claude:claude-build" "$PI_LAUNCHER:pi:pi-build")

for entry in "${LAUNCHERS[@]}"; do
    LAUNCHER="${entry%%:*}"
    rest="${entry#*:}"
    HARNESS="${rest%%:*}"
    MSGPFX="${rest#*:}"

    # ── Case 1: CODEGEN_DIR override — --queue → mix codegen.loop.queue ──
    WS1="$(make_ws "${HARNESS}_c1")"
    mkdir -p "$WS1/test_harness"
    MIXDIR1="$(make_mix_stub_dir "${HARNESS}_c1_mix")"

    ec=0
    OUT1="$BASE_TMP/${HARNESS}_c1_pwd"
    mkdir -p "$OUT1"
    (
        cd "$OUT1"
        OCG_CODEGEN_DIR="$WS1" PATH="$MIXDIR1:$PATH" "$LAUNCHER" --queue
    ) >/dev/null 2>"$BASE_TMP/${HARNESS}_c1_stderr" || ec=$?
    check "(1:$HARNESS) --queue override exits 0" "0" "$ec"
    assert_capture_exists "(1:$HARNESS) mix stub capture exists" "$MIXDIR1/mix_capture.txt"
    if [[ -f "$MIXDIR1/mix_capture.txt" ]]; then
        MIX1C="$(cat "$MIXDIR1/mix_capture.txt")"
        assert_contains "(1:$HARNESS) codegen.loop.queue invoked" "$MIX1C" "codegen.loop.queue"
        assert_contains "(1:$HARNESS) --harness=$HARNESS passed" "$MIX1C" "--harness=$HARNESS"
        assert_contains "(1:$HARNESS) --stack=phoenix default" "$MIX1C" "--stack=phoenix"
        assert_contains "(1:$HARNESS) --cwd passed" "$MIX1C" "--cwd=$OUT1"
    fi

    # ── Case 2: CODEGEN_DIR installed-flat — copy launcher, harnesses/ dir present ──
    FLAT_ROOT="$BASE_TMP/${HARNESS}_c2_flat"
    mkdir -p "$FLAT_ROOT/harnesses" "$FLAT_ROOT/test_harness"
    cp "$LAUNCHER" "$FLAT_ROOT/launcher.sh"
    chmod +x "$FLAT_ROOT/launcher.sh"
    MIXDIR2="$(make_mix_stub_dir "${HARNESS}_c2_mix")"

    ec=0
    env -u OCG_CODEGEN_DIR PATH="$MIXDIR2:$PATH" "$FLAT_ROOT/launcher.sh" --queue \
        >/dev/null 2>"$BASE_TMP/${HARNESS}_c2_stderr" || ec=$?
    check "(2:$HARNESS) installed-flat resolves + exits 0" "0" "$ec"
    assert_capture_exists "(2:$HARNESS) mix stub capture exists (installed-flat)" "$MIXDIR2/mix_capture.txt"
    if [[ -f "$MIXDIR2/mix_capture.txt" ]]; then
        assert_contains "(2:$HARNESS) codegen.loop.queue invoked (installed-flat)" \
            "$(cat "$MIXDIR2/mix_capture.txt")" "codegen.loop.queue"
    fi

    # ── Case 3: CODEGEN_DIR in-repo fallback — copy launcher 2 dirs deep, no harnesses/ ──
    REPO_ROOT="$BASE_TMP/${HARNESS}_c3_repo"
    mkdir -p "$REPO_ROOT/a/b" "$REPO_ROOT/test_harness"
    cp "$LAUNCHER" "$REPO_ROOT/a/b/launcher.sh"
    chmod +x "$REPO_ROOT/a/b/launcher.sh"
    MIXDIR3="$(make_mix_stub_dir "${HARNESS}_c3_mix")"

    ec=0
    env -u OCG_CODEGEN_DIR PATH="$MIXDIR3:$PATH" "$REPO_ROOT/a/b/launcher.sh" --queue \
        >/dev/null 2>"$BASE_TMP/${HARNESS}_c3_stderr" || ec=$?
    check "(3:$HARNESS) in-repo fallback resolves + exits 0" "0" "$ec"
    assert_capture_exists "(3:$HARNESS) mix stub capture exists (in-repo fallback)" "$MIXDIR3/mix_capture.txt"
    if [[ -f "$MIXDIR3/mix_capture.txt" ]]; then
        assert_contains "(3:$HARNESS) codegen.loop.queue invoked (in-repo fallback)" \
            "$(cat "$MIXDIR3/mix_capture.txt")" "codegen.loop.queue"
    fi

    # ── Case 4: --queue, test_harness/ absent → exit 2 ──
    WS4="$(make_ws "${HARNESS}_c4")"
    # deliberately no test_harness dir under $WS4
    MIXDIR4="$(make_mix_stub_dir "${HARNESS}_c4_mix")"

    ec=0
    STDERR4="$BASE_TMP/${HARNESS}_c4_stderr"
    OCG_CODEGEN_DIR="$WS4" PATH="$MIXDIR4:$PATH" "$LAUNCHER" --queue \
        >/dev/null 2>"$STDERR4" || ec=$?
    check "(4:$HARNESS) missing test_harness/ exits 2" "2" "$ec"
    assert_contains "(4:$HARNESS) stderr mentions test_harness/ not found" "$(cat "$STDERR4")" "test_harness/ not found"
    if [[ -f "$MIXDIR4/mix_capture.txt" ]]; then
        printf 'FAIL: (4:%s) mix stub was invoked despite missing test_harness/\n' "$HARNESS"
        fail=$((fail + 1))
    else
        [ -n "${VERBOSE:-}" ] && printf 'PASS: (4:%s) mix stub NOT invoked\n' "$HARNESS"
        pass=$((pass + 1))
    fi

    # ── Case 5: --queue alone → exec mix codegen.loop.queue ──
    WS5="$(make_ws "${HARNESS}_c5")"
    mkdir -p "$WS5/test_harness"
    MIXDIR5="$(make_mix_stub_dir "${HARNESS}_c5_mix")"

    ec=0
    STDERR5="$BASE_TMP/${HARNESS}_c5_stderr"
    OCG_CODEGEN_DIR="$WS5" PATH="$MIXDIR5:$PATH" "$LAUNCHER" --queue >/dev/null 2>"$STDERR5" || ec=$?
    check "(5:$HARNESS) --queue exits 0" "0" "$ec"
    assert_capture_exists "(5:$HARNESS) mix stub capture exists" "$MIXDIR5/mix_capture.txt"
    if [[ -f "$MIXDIR5/mix_capture.txt" ]]; then
        MIX5C="$(cat "$MIXDIR5/mix_capture.txt")"
        assert_contains "(5:$HARNESS) codegen.loop.queue invoked" "$MIX5C" "codegen.loop.queue"
        assert_contains "(5:$HARNESS) --harness=$HARNESS passed" "$MIX5C" "--harness=$HARNESS"
        assert_contains "(5:$HARNESS) --stack=phoenix default" "$MIX5C" "--stack=phoenix"
    fi

    # ── Case 7: --queue foo (slug arg) → exit 1 usage error ──
    WS7="$(make_ws "${HARNESS}_c7")"
    ec=0
    STDERR7="$BASE_TMP/${HARNESS}_c7_stderr"
    OCG_CODEGEN_DIR="$WS7" "$LAUNCHER" --queue foo >/dev/null 2>"$STDERR7" || ec=$?
    check "(7:$HARNESS) --queue with slug arg exits 1" "1" "$ec"
    assert_contains "(7:$HARNESS) stderr: --queue takes no slug arguments" "$(cat "$STDERR7")" "--queue takes no slug arguments"
    if [[ -f "$WS7/cb_capture.txt" ]]; then
        printf 'FAIL: (7:%s) codegen-build stub was invoked despite usage error\n' "$HARNESS"
        fail=$((fail + 1))
    else
        [ -n "${VERBOSE:-}" ] && printf 'PASS: (7:%s) codegen-build stub NOT invoked\n' "$HARNESS"
        pass=$((pass + 1))
    fi

    # ── Case 8: ready/ slug basename resolves ──
    WS8="$(make_ws "${HARNESS}_c8")"
    mkdir -p "$WS8/codegen/pitches/ready"
    printf '# a real ready pitch\n' >"$WS8/codegen/pitches/ready/my-real-slug.md"

    ec=0
    (
        cd "$WS8"
        OCG_CODEGEN_DIR="$WS8" "$LAUNCHER" my-real-slug
    ) >/dev/null 2>/dev/null || ec=$?
    check "(8:$HARNESS) <slug> exits 0" "0" "$ec"
    assert_capture_exists "(8:$HARNESS) codegen-build stub capture exists" "$WS8/cb_capture.txt"
    if [[ -f "$WS8/cb_capture.txt" ]]; then
        CB8C="$(cat "$WS8/cb_capture.txt")"
        if [[ "$HARNESS" == "claude" ]]; then
            assert_contains "(8:$HARNESS) @-mention resolved" "$CB8C" "@codegen/pitches/ready/my-real-slug.md"
        else
            assert_contains "(8:$HARNESS) bare mention resolved" "$CB8C" "codegen/pitches/ready/my-real-slug.md"
        fi
    fi

    # ── Case 9: basename ready/ slug exact match ──
    WS9="$(make_ws "${HARNESS}_c9")"
    mkdir -p "$WS9/codegen/pitches/ready"
    printf '# ready\n' >"$WS9/codegen/pitches/ready/exact-match-slug.md"

    ec=0
    (
        cd "$WS9"
        OCG_CODEGEN_DIR="$WS9" "$LAUNCHER" exact-match-slug
    ) >/dev/null 2>/dev/null || ec=$?
    check "(9:$HARNESS) exact-match slug exits 0" "0" "$ec"
    assert_capture_exists "(9:$HARNESS) codegen-build stub capture exists" "$WS9/cb_capture.txt"
    if [[ -f "$WS9/cb_capture.txt" ]]; then
        CB9C="$(cat "$WS9/cb_capture.txt")"
        if [[ "$HARNESS" == "claude" ]]; then
            assert_contains "(9:$HARNESS) @-mention resolved exact match" "$CB9C" "@codegen/pitches/ready/exact-match-slug.md"
        else
            assert_contains "(9:$HARNESS) bare mention resolved exact match" "$CB9C" "codegen/pitches/ready/exact-match-slug.md"
        fi
    fi

    # ── Case 10: ambiguous prefix match → exit 1 + list ──
    WS10="$(make_ws "${HARNESS}_c10")"
    mkdir -p "$WS10/codegen/pitches/ready"
    printf '# a\n' >"$WS10/codegen/pitches/ready/foo-a.md"
    printf '# b\n' >"$WS10/codegen/pitches/ready/foo-b.md"

    ec=0
    STDERR10="$BASE_TMP/${HARNESS}_c10_stderr"
    (
        cd "$WS10"
        OCG_CODEGEN_DIR="$WS10" "$LAUNCHER" foo
    ) >/dev/null 2>"$STDERR10" || ec=$?
    check "(10:$HARNESS) ambiguous prefix exits 1" "1" "$ec"
    STDERR10C="$(cat "$STDERR10")"
    assert_contains "(10:$HARNESS) stderr mentions ambiguous" "$STDERR10C" "ambiguous"
    assert_contains "(10:$HARNESS) stderr lists foo-a" "$STDERR10C" "foo-a"
    assert_contains "(10:$HARNESS) stderr lists foo-b" "$STDERR10C" "foo-b"
    if [[ -f "$WS10/cb_capture.txt" ]]; then
        printf 'FAIL: (10:%s) codegen-build stub invoked despite ambiguous error\n' "$HARNESS"
        fail=$((fail + 1))
    else
        [ -n "${VERBOSE:-}" ] && printf 'PASS: (10:%s) codegen-build stub NOT invoked\n' "$HARNESS"
        pass=$((pass + 1))
    fi

    # ── Case 11: no match → passthrough literal ──
    WS11="$(make_ws "${HARNESS}_c11")"
    mkdir -p "$WS11/codegen/pitches/ready"

    ec=0
    (
        cd "$WS11"
        OCG_CODEGEN_DIR="$WS11" "$LAUNCHER" nonexistentslug
    ) >/dev/null 2>/dev/null || ec=$?
    check "(11:$HARNESS) no-match slug exits 0" "0" "$ec"
    assert_capture_exists "(11:$HARNESS) codegen-build stub capture exists" "$WS11/cb_capture.txt"
    if [[ -f "$WS11/cb_capture.txt" ]]; then
        assert_contains "(11:$HARNESS) no-match forwarded literally" "$(cat "$WS11/cb_capture.txt")" "nonexistentslug"
    fi

    # ── Case 12: passthrough unchanged for /, .md, space args ──
    WS12="$(make_ws "${HARNESS}_c12")"
    mkdir -p "$WS12/codegen/pitches/ready"

    ec=0
    (
        cd "$WS12"
        OCG_CODEGEN_DIR="$WS12" "$LAUNCHER" "a/b" "x.md" "hello world"
    ) >/dev/null 2>/dev/null || ec=$?
    check "(12:$HARNESS) passthrough args exits 0" "0" "$ec"
    assert_capture_exists "(12:$HARNESS) codegen-build stub capture exists" "$WS12/cb_capture.txt"
    if [[ -f "$WS12/cb_capture.txt" ]]; then
        CB12C="$(cat "$WS12/cb_capture.txt")"
        assert_contains "(12:$HARNESS) a/b forwarded verbatim" "$CB12C" "a/b"
        assert_contains "(12:$HARNESS) x.md forwarded verbatim" "$CB12C" "x.md"
        assert_contains "(12:$HARNESS) hello world forwarded verbatim" "$CB12C" "hello world"
        assert_not_contains "(12:$HARNESS) no @-mention injected for a/b" "$CB12C" "@a/b"
    fi

    # ── Case 13: cwd normalization — launched inside codegen/pitches/ready ──
    WS13="$(make_ws "${HARNESS}_c13")"
    mkdir -p "$WS13/codegen/pitches/ready"
    printf '# ready\n' >"$WS13/codegen/pitches/ready/norm-slug.md"

    ec=0
    STDERR13="$BASE_TMP/${HARNESS}_c13_stderr"
    (
        cd "$WS13/codegen/pitches/ready"
        OCG_CODEGEN_DIR="$WS13" "$LAUNCHER" norm-slug
    ) >/dev/null 2>"$STDERR13" || ec=$?
    check "(13:$HARNESS) cwd-normalized run exits 0" "0" "$ec"
    STDERR13C="$(cat "$STDERR13")"
    assert_contains "(13:$HARNESS) stderr shows launched-inside message" "$STDERR13C" "launched inside codegen/pitches"
    assert_contains "(13:$HARNESS) stderr names repo root basename" "$STDERR13C" "$(basename "$WS13")"
    assert_capture_exists "(13:$HARNESS) codegen-build stub capture exists" "$WS13/cb_capture.txt"
    if [[ -f "$WS13/cb_capture.txt" ]]; then
        if [[ "$HARNESS" == "claude" ]]; then
            assert_contains "(13:$HARNESS) mention resolved against repo root" "$(cat "$WS13/cb_capture.txt")" "@codegen/pitches/ready/norm-slug.md"
        else
            assert_contains "(13:$HARNESS) mention resolved against repo root" "$(cat "$WS13/cb_capture.txt")" "codegen/pitches/ready/norm-slug.md"
        fi
    fi

    # ── Case 14: harness/stack flags — STACK unset → launcher omits --stack
    # entirely (no silent default); codegen-build itself hard-requires --stack. ──
    WS14="$(make_ws "${HARNESS}_c14")"
    ec=0
    (
        cd "$WS14"
        unset STACK
        OCG_CODEGEN_DIR="$WS14" "$LAUNCHER" "flag check prompt"
    ) >/dev/null 2>/dev/null || ec=$?
    check "(14:$HARNESS) default flags run exits 0" "0" "$ec"
    assert_capture_exists "(14:$HARNESS) codegen-build stub capture exists (default)" "$WS14/cb_capture.txt"
    if [[ -f "$WS14/cb_capture.txt" ]]; then
        CB14C="$(cat "$WS14/cb_capture.txt")"
        assert_contains "(14:$HARNESS) --harness=$HARNESS passed" "$CB14C" "--harness=$HARNESS"
        assert_not_contains "(14:$HARNESS) no silent --stack=phoenix default when STACK unset" "$CB14C" "--stack="
    fi

    WS14B="$(make_ws "${HARNESS}_c14b")"
    ec=0
    (
        cd "$WS14B"
        OCG_CODEGEN_DIR="$WS14B" STACK="static" "$LAUNCHER" "flag check prompt"
    ) >/dev/null 2>/dev/null || ec=$?
    check "(14b:$HARNESS) STACK=static run exits 0" "0" "$ec"
    assert_capture_exists "(14b:$HARNESS) codegen-build stub capture exists (STACK override)" "$WS14B/cb_capture.txt"
    if [[ -f "$WS14B/cb_capture.txt" ]]; then
        assert_contains "(14b:$HARNESS) --stack=static honored" "$(cat "$WS14B/cb_capture.txt")" "--stack=static"
    fi

done

# ─────────────────────────────────────────────────────────────────────────
echo ""
echo "Results: $pass passed, $fail failed"

if [[ "$fail" -gt 0 ]]; then
    exit 1
fi
exit 0
