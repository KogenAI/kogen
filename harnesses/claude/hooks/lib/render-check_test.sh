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

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
