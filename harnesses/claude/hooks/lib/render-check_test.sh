#!/usr/bin/env bash
# render-check_test.sh — parse regression guard for render-check.js and phoenix-server.js
#
# Verifies that both JS files parse without SyntaxError (node --check).
# Catches duplicate function definition bugs like the allocFreePort/waitForHttp200
# duplication that masked the whole file under "use strict" from Jun 3 to Jun 8 2026.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

pass=0
fail=0

# ── Test 1: render-check.js parses cleanly ───────────────────────────────────
if node --check "$SCRIPT_DIR/render-check.js" 2>/dev/null; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: render-check.js node --check\n'
    pass=$((pass + 1))
else
    printf 'FAIL: render-check.js node --check — SyntaxError (duplicate fn defs or bad import?)\n'
    node --check "$SCRIPT_DIR/render-check.js" 2>&1 || true
    fail=$((fail + 1))
fi

# ── Test 2: phoenix-server.js parses cleanly ─────────────────────────────────
if node --check "$SCRIPT_DIR/phoenix-server.js" 2>/dev/null; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: phoenix-server.js node --check\n'
    pass=$((pass + 1))
else
    printf 'FAIL: phoenix-server.js node --check — SyntaxError\n'
    node --check "$SCRIPT_DIR/phoenix-server.js" 2>&1 || true
    fail=$((fail + 1))
fi

# ── Test 3: phoenix-server.js require() succeeds ─────────────────────────────
# Require phoenix-server.js and verify it loads without runtime error.
# Run in a subprocess so module state does not affect this process.
if (cd "$SCRIPT_DIR" && node -e "require('./phoenix-server.js')") 2>/dev/null; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: phoenix-server.js require() succeeds\n'
    pass=$((pass + 1))
else
    printf 'FAIL: phoenix-server.js require() threw — missing deps or runtime error\n'
    (cd "$SCRIPT_DIR" && node -e "require('./phoenix-server.js')") 2>&1 || true
    fail=$((fail + 1))
fi

# ── Test 4: playwright module unresolvable → distinct verdict ────────────────
# Copy render-check.js + phoenix-server.js into a temp dir several levels deep
# with no node_modules at any ancestor. Run with CODEGEN_DIR unset and cwd inside
# the temp dir to defeat all three playwright resolution candidates.
# Asserts the new INCONCLUSIVE:playwright-module-unresolvable verdict is emitted
# and that the old browser-not-installed label is NOT used.
_t4_root=$(mktemp -d)
# Place files deep enough so __dirname four-up has no node_modules
_t4_lib="$_t4_root/a/b/c/d/lib"
mkdir -p "$_t4_lib"
cp "$SCRIPT_DIR/render-check.js" "$_t4_lib/"
cp "$SCRIPT_DIR/phoenix-server.js" "$_t4_lib/"
_t4_out_dir="$_t4_root/out"
mkdir -p "$_t4_out_dir"
# Provide index.html so main() passes the config checks and reaches runChecks()
printf '<html><body><p>test</p></body></html>\n' >"$_t4_out_dir/index.html"
# Run from inside the deep dir so node-default resolution also fails
_t4_result=$(
    cd "$_t4_lib"
    env -u CODEGEN_DIR node ./render-check.js --mode static --timeout 5000 "$_t4_out_dir" 2>/dev/null || true
)
if printf '%s' "$_t4_result" | grep -qF 'RENDER_VERDICT=INCONCLUSIVE:playwright-module-unresolvable'; then
    if ! printf '%s' "$_t4_result" | grep -qF 'browser-not-installed'; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: playwright-module-unresolvable verdict (not browser-not-installed)\n'
        pass=$((pass + 1))
    else
        printf 'FAIL: playwright-module-unresolvable verdict still contains browser-not-installed\n  result: %s\n' "$_t4_result"
        fail=$((fail + 1))
    fi
else
    printf 'FAIL: expected RENDER_VERDICT=INCONCLUSIVE:playwright-module-unresolvable\n  result: %s\n' "$_t4_result"
    fail=$((fail + 1))
fi
rm -rf "$_t4_root"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
