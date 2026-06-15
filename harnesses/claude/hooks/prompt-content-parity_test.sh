#!/usr/bin/env bash
# prompt-content-parity_test.sh — verify sentinel strings are present in baked prompts

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODEGEN_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

SENTINEL="ASK-GATE: product forks only"
SENTINEL2="INTERACTION-AUDIT: compose-check siblings"
SENTINEL3="Never treat N prose/image-named pitches as one combined task."
SENTINEL4="NEVER pre-seed role section headers in the initial Write; each role section header is inserted exactly once, immediately before that role's spawn — never re-add a header that already exists."

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

# ── Tests 6-8: LiveView correctness facts in phoenix _core.md ─────────────────
assert_contains \
    "LiveView <form> ancestor fact in phoenix _core.md" \
    "$CODEGEN_DIR/shared/rules/stacks/phoenix/_core.md" \
    "require a \`<form>\` ancestor"

assert_contains \
    "LiveView layout: false fact in phoenix _core.md" \
    "$CODEGEN_DIR/shared/rules/stacks/phoenix/_core.md" \
    "layout: false"

assert_contains \
    "LiveView phx-mounted focus fact in phoenix _core.md" \
    "$CODEGEN_DIR/shared/rules/stacks/phoenix/_core.md" \
    "phx-mounted={JS.focus()}"

# ── Tests 9-10: mechanism-question sentinel in shape baked prompts ────────────
assert_contains \
    "mechanism-question sentinel in claude-shape-system-prompt.txt" \
    "$CODEGEN_DIR/harnesses/claude/claude-shape-system-prompt.txt" \
    "same observable behavior"

assert_contains \
    "mechanism-question sentinel in pi-shape-system-prompt.txt" \
    "$CODEGEN_DIR/harnesses/pi/pi-shape-system-prompt.txt" \
    "same observable behavior"

# ── Tests 11-14: LiveView correctness checklist in phoenix reviewer.md ────────
assert_contains \
    "LiveView correctness: form events" \
    "$CODEGEN_DIR/shared/rules/stacks/phoenix/reviewer.md" \
    "require a \`<.form>\`/\`<form>\` ancestor"

assert_contains \
    "LiveView correctness: double-layout render" \
    "$CODEGEN_DIR/shared/rules/stacks/phoenix/reviewer.md" \
    "causes double-layout render"

assert_contains \
    "LiveView correctness: autofocus" \
    "$CODEGEN_DIR/shared/rules/stacks/phoenix/reviewer.md" \
    "keyboard-first overlay/modal input"

assert_contains \
    "LiveView correctness: cursor" \
    "$CODEGEN_DIR/shared/rules/stacks/phoenix/reviewer.md" \
    "Tailwind preflight resets to"

# ── Tests 15-16: prose/image-named pitch trigger in baked build prompts ───────
assert_contains \
    "prose/image-named-pitch sentinel in claude-build-system-prompt.txt" \
    "$CODEGEN_DIR/harnesses/claude/claude-build-system-prompt.txt" \
    "$SENTINEL3"

assert_contains \
    "prose/image-named-pitch sentinel in pi-build-system-prompt.txt" \
    "$CODEGEN_DIR/harnesses/pi/pi-build-system-prompt.txt" \
    "$SENTINEL3"

# ── Tests 17-18: NEVER pre-seed sentinel in both baked build prompts ─────────
assert_contains \
    "no-duplicate-section NEVER sentinel in claude-build-system-prompt.txt" \
    "$CODEGEN_DIR/harnesses/claude/claude-build-system-prompt.txt" \
    "$SENTINEL4"

assert_contains \
    "no-duplicate-section NEVER sentinel in pi-build-system-prompt.txt" \
    "$CODEGEN_DIR/harnesses/pi/pi-build-system-prompt.txt" \
    "$SENTINEL4"

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
