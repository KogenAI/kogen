#!/usr/bin/env bash
# test-stub-lib_test.sh — unit tests for test-stub-lib.sh
# Auto-discovered by `harness-parity`'s harnesses/shared/*_test.sh glob (Makefile:164).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SCRIPT_DIR/test-stub-lib.sh"

pass=0
fail=0

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' "$desc" "$expected" "$actual"
        fail=$((fail + 1))
    fi
}

assert_true() {
    local desc="$1" cond="$2"
    if [ "$cond" = "0" ]; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s (cond=%s)\n' "$desc" "$cond"
        fail=$((fail + 1))
    fi
}

# shellcheck source=/dev/null
source "$LIB"

TMPDIR_T=$(mktemp -d)
trap 'rm -rf "$TMPDIR_T"' EXIT

# --- T1: two make_stub calls produce the SAME inode (one shared trampoline) ---
make_stub "$TMPDIR_T/stub_a" 'echo body-a' >/dev/null
make_stub "$TMPDIR_T/stub_b" 'echo body-b' >/dev/null
INODE_A=$(stat -c '%i' "$TMPDIR_T/stub_a" 2>/dev/null || stat -f '%i' "$TMPDIR_T/stub_a")
INODE_B=$(stat -c '%i' "$TMPDIR_T/stub_b" 2>/dev/null || stat -f '%i' "$TMPDIR_T/stub_b")
assert_eq "T1: two stubs share the same trampoline inode" "$INODE_A" "$INODE_B"

# --- T2: .body resolves via dirname "$0" when invoked relative, via PATH, absolute-from-/ ---
OUT_REL=$(cd "$TMPDIR_T" && ./stub_a)
assert_eq "T2: relative invocation resolves body" "body-a" "$OUT_REL"

OUT_ABS=$("$TMPDIR_T/stub_a")
assert_eq "T2: absolute invocation resolves body" "body-a" "$OUT_ABS"

OUT_PATH=$(PATH="$TMPDIR_T:$PATH" stub_a)
assert_eq "T2: PATH-search invocation resolves body" "body-a" "$OUT_PATH"

# --- T3: link_or_copy falls back to cp when ln fails ---
SRC_FILE="$TMPDIR_T/real_exe"
printf '#!/usr/bin/env bash\necho real-output\n' >"$SRC_FILE"
chmod +x "$SRC_FILE"

# Simulate ln failure by stubbing PATH's ln to exit 1.
FAKE_BIN_DIR="$TMPDIR_T/fakebin"
mkdir -p "$FAKE_BIN_DIR"
printf '#!/usr/bin/env bash\nexit 1\n' >"$FAKE_BIN_DIR/ln"
chmod +x "$FAKE_BIN_DIR/ln"

DST_FILE="$TMPDIR_T/copied_exe"
(PATH="$FAKE_BIN_DIR:$PATH" link_or_copy "$SRC_FILE" "$DST_FILE")
assert_true "T3: link_or_copy fallback produced an executable file" "$([ -x "$DST_FILE" ] && echo 0 || echo 1)"
T3_OUT=$("$DST_FILE")
assert_eq "T3: fallback-copied file runs correctly" "real-output" "$T3_OUT"

# --- T4: _warm_replace on an already-linked path does not corrupt the shared trampoline ---
make_stub "$TMPDIR_T/stub_c" 'echo before-replace' >/dev/null
_warm_replace "$TMPDIR_T/stub_c" 'echo after-replace' >/dev/null
OUT_C=$("$TMPDIR_T/stub_c")
assert_eq "T4: _warm_replace updates this stub's own body" "after-replace" "$OUT_C"

# Assert the trampoline itself is untouched (still just execs "$0.body")
TRAMPOLINE_PATH="$(_ensure_trampoline)"
TRAMPOLINE_CONTENT=$(cat "$TRAMPOLINE_PATH")
assert_eq "T4: trampoline content unchanged after _warm_replace" \
    "$(printf '#!/usr/bin/env bash\nexec bash \"$0.body\" \"$@\"')" \
    "$TRAMPOLINE_CONTENT"

# Assert a sibling stub (stub_a) still works after stub_c's _warm_replace
OUT_A_AFTER=$("$TMPDIR_T/stub_a")
assert_eq "T4: sibling stub unaffected by _warm_replace on another stub" "body-a" "$OUT_A_AFTER"

# --- T4b: link_stub_path (heredoc-body call sites) shares the same trampoline inode ---
mkdir -p "$TMPDIR_T/heredoc_bin"
cat >"$TMPDIR_T/heredoc_bin/stub_d.body" <<'HEREDOCBODY'
#!/usr/bin/env bash
echo body-d
HEREDOCBODY
link_stub_path "$TMPDIR_T/heredoc_bin/stub_d"
OUT_D=$("$TMPDIR_T/heredoc_bin/stub_d")
assert_eq "T4b: link_stub_path stub runs its heredoc-written body" "body-d" "$OUT_D"

INODE_D=$(stat -c '%i' "$TMPDIR_T/heredoc_bin/stub_d" 2>/dev/null || stat -f '%i' "$TMPDIR_T/heredoc_bin/stub_d")
assert_eq "T4b: link_stub_path shares the same trampoline inode as make_stub" "$INODE_A" "$INODE_D"

# --- T4c: link_or_copy aliasing a trampoline stub requires copying the .body too ---
mkdir -p "$TMPDIR_T/alias_bin"
make_stub "$TMPDIR_T/alias_bin/orig" 'echo orig-body' >/dev/null
link_or_copy "$TMPDIR_T/alias_bin/orig" "$TMPDIR_T/alias_bin/alias"
link_or_copy "$TMPDIR_T/alias_bin/orig.body" "$TMPDIR_T/alias_bin/alias.body"
OUT_ALIAS=$("$TMPDIR_T/alias_bin/alias")
assert_eq "T4c: aliased trampoline stub runs correctly when .body is also linked" "orig-body" "$OUT_ALIAS"

# --- T5: make_stub fail-loud on empty path/body ---
set +e
(make_stub "" "some body") >/dev/null 2>&1
T5_EMPTY_PATH=$?
(make_stub "$TMPDIR_T/stub_empty_body" "") >/dev/null 2>&1
T5_EMPTY_BODY=$?
set -e
assert_true "T5: make_stub rejects empty path" "$([ "$T5_EMPTY_PATH" -ne 0 ] && echo 0 || echo 1)"
assert_true "T5: make_stub rejects empty body" "$([ "$T5_EMPTY_BODY" -ne 0 ] && echo 0 || echo 1)"

printf '\nResults: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
