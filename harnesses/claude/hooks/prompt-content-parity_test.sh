#!/usr/bin/env bash
# prompt-content-parity_test.sh — verify sentinel strings are present in baked prompts

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODEGEN_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

SENTINEL="ASK-GATE: customer-facing forks only"
SENTINEL2="INTERACTION-AUDIT: compose-check siblings"

pass=0
fail=0

assert_contains() {
    local desc="$1"
    local file="$2"
    local pattern="$3"
    if grep -qF "$pattern" "$file" 2>/dev/null; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s — sentinel absent in %s\n' "$desc" "$file"
        fail=$((fail + 1))
    fi
}

# ── Test 1: sentinel present in claude shape baked prompt ─────────────────────
assert_contains \
    "ASK-GATE sentinel in claude-shape-system-prompt.txt" \
    "$CODEGEN_DIR/harnesses/claude/claude-shape-system-prompt.txt" \
    "$SENTINEL"

# ── Test 2: sentinel present in pi shape baked prompt ─────────────────────────
assert_contains \
    "ASK-GATE sentinel in pi-shape-system-prompt.txt" \
    "$CODEGEN_DIR/harnesses/pi/pi-shape-system-prompt.txt" \
    "$SENTINEL"

# ── Test 3: INTERACTION-AUDIT sentinel present in claude shape baked prompt ───
assert_contains \
    "INTERACTION-AUDIT sentinel in claude-shape-system-prompt.txt" \
    "$CODEGEN_DIR/harnesses/claude/claude-shape-system-prompt.txt" \
    "$SENTINEL2"

# ── Test 4: INTERACTION-AUDIT sentinel present in pi shape baked prompt ───────
assert_contains \
    "INTERACTION-AUDIT sentinel in pi-shape-system-prompt.txt" \
    "$CODEGEN_DIR/harnesses/pi/pi-shape-system-prompt.txt" \
    "$SENTINEL2"

# ── Test 5: sentinel present in ready.md.j2 source ────────────────────────────
assert_contains \
    "ASK-GATE sentinel in ready.md.j2" \
    "$CODEGEN_DIR/harnesses/claude/commands/ready.md.j2" \
    "$SENTINEL"

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
