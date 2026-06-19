#!/usr/bin/env bash
# install_test.sh — unit tests for install.sh pi-extension npm failure propagation.
#
# Tests (3):
#   1: npm exit-code capture propagates non-zero (no | sed masking)
#   2: success path prints the pi-extension success echo
#   3: error message contains the required description string on failure

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

assert_contains() {
    local desc="$1"
    local needle="$2"
    local haystack="$3"
    if printf '%s' "$haystack" | grep -qF "$needle"; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s\n  needle not found: %s\n' "$desc" "$needle"
        fail=$((fail + 1))
    fi
}

assert_not_contains() {
    local desc="$1"
    local needle="$2"
    local haystack="$3"
    if printf '%s' "$haystack" | grep -qF "$needle"; then
        printf 'FAIL: %s\n  needle found (should not be): %s\n' "$desc" "$needle"
        fail=$((fail + 1))
    else
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    fi
}

# ── Setup: extract the pi-extension npm block from install.sh ─────────────────
# The block we're testing is the _pi_ext_install_failed=0 ... fi pattern introduced
# in install.sh to replace the silent `| sed` pipe. We reproduce its logic
# inline in a test subshell to assert exit-code propagation behaviour.

INSTALL_SH="$SCRIPT_DIR/../../install.sh"

# Verify the old silent-failure pattern is gone (| sed masking removed).
install_content=$(<"$INSTALL_SH")

assert_not_contains \
    "old | sed masking removed from pi-extension npm block" \
    "npm install --prefer-offline 2>&1 | sed" \
    "$install_content"

# Verify the status-var pattern is present.
assert_contains \
    "status-var pattern present: _pi_ext_install_failed=0" \
    "_pi_ext_install_failed=0" \
    "$install_content"

# Verify the fail-loud message is present.
assert_contains \
    "fail-loud message present in install.sh" \
    "pi-extension npm install failed:" \
    "$install_content"

# ── Test 1: forced-failing npm → exit non-zero ───────────────────────────────
# Reproduce the exact status-var pattern from install.sh in a subshell.
# `false` simulates a failing `npm install`.

tmpdir=$(mktemp -d /tmp/install_test_XXXXXX)
trap 'rm -rf "$tmpdir"' EXIT

_ext_name="test-ext"
_ext_dir="$tmpdir/test-ext"
mkdir -p "$_ext_dir"

# Write a fake npm that exits 1.
mkdir -p "$tmpdir/bin"
printf '#!/usr/bin/env bash\nexit 1\n' >"$tmpdir/bin/fake_npm"
chmod +x "$tmpdir/bin/fake_npm"

# Subshell reproducing the install.sh pi-extension npm block with a fake npm.
npm_exit=0
capture=$(
    _pi_ext_install_failed=0
    (cd "$_ext_dir" && "$tmpdir/bin/fake_npm" install --prefer-offline) 2>&1 || _pi_ext_install_failed=1
    if [ "$_pi_ext_install_failed" -eq 1 ]; then
        echo "❌ pi-extension npm install failed: $_ext_name — extension ships broken"
        exit 1
    fi
    echo "   ✅ pi-extension deps installed: $_ext_name"
) 2>&1 || npm_exit=$?

assert_eq "forced-failing npm → exit non-zero" "1" "$npm_exit"
assert_contains "error message on failure" "pi-extension npm install failed" "$capture"
assert_not_contains "success echo NOT printed on failure" "✅ pi-extension deps installed" "$capture"

# ── Test 2: succeeding npm → exit 0 and success echo ─────────────────────────

# Write a fake npm that exits 0.
printf '#!/usr/bin/env bash\nexit 0\n' >"$tmpdir/bin/fake_npm_ok"
chmod +x "$tmpdir/bin/fake_npm_ok"

npm_ok_exit=0
capture_ok=$(
    _pi_ext_install_failed=0
    (cd "$_ext_dir" && "$tmpdir/bin/fake_npm_ok" install --prefer-offline) 2>&1 || _pi_ext_install_failed=1
    if [ "$_pi_ext_install_failed" -eq 1 ]; then
        echo "❌ pi-extension npm install failed: $_ext_name — extension ships broken"
        exit 1
    fi
    echo "   ✅ pi-extension deps installed: $_ext_name"
) 2>&1 || npm_ok_exit=$?

assert_eq "succeeding npm → exit 0" "0" "$npm_ok_exit"
assert_contains "success echo printed on success" "pi-extension deps installed: test-ext" "$capture_ok"
assert_not_contains "error message NOT printed on success" "pi-extension npm install failed" "$capture_ok"

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi
exit 0
