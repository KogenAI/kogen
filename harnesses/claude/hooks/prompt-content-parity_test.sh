#!/usr/bin/env bash
# prompt-content-parity_test.sh — verify sentinel strings are present in baked prompts

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODEGEN_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

SENTINEL="ASK-GATE: product forks only"
SENTINEL2="INTERACTION-AUDIT: compose-check siblings"
SENTINEL5="SWEEP-CLASS COMPLETENESS:"
SENTINEL6="Latent contract-mirror fork"
SENTINEL7="NEVER fail open by default"
SENTINEL8="Lowercase letters/digits/hyphens only. No colons"
SENTINEL9="context files are hints, probes are evidence"
SENTINEL9_PLANNER="only \`ran:\` against git/fs counts"

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

assert_absent() {
    local desc="$1"
    local file="$2"
    local pattern="$3"
    if grep -qF "$pattern" "$file" 2>/dev/null; then
        printf 'FAIL: %s — forbidden sentinel present in %s\n' "$desc" "$file"
        fail=$((fail + 1))
    else
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
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

# ── Tests 19-21: SWEEP-CLASS COMPLETENESS sentinel in shape prompts + ready ───
assert_contains \
    "SWEEP-CLASS COMPLETENESS sentinel in claude-shape-system-prompt.txt" \
    "$CODEGEN_DIR/harnesses/claude/claude-shape-system-prompt.txt" \
    "$SENTINEL5"

assert_contains \
    "SWEEP-CLASS COMPLETENESS sentinel in pi-shape-system-prompt.txt" \
    "$CODEGEN_DIR/harnesses/pi/pi-shape-system-prompt.txt" \
    "$SENTINEL5"

assert_contains \
    "SWEEP-CLASS COMPLETENESS sentinel in ready.md.j2" \
    "$CODEGEN_DIR/harnesses/claude/commands/ready.md.j2" \
    "$SENTINEL5"

# ── Tests 22-24: Latent contract-mirror fork sentinel in shape prompts + ready ──
assert_contains \
    "Latent contract-mirror fork sentinel in claude-shape-system-prompt.txt" \
    "$CODEGEN_DIR/harnesses/claude/claude-shape-system-prompt.txt" \
    "$SENTINEL6"

assert_contains \
    "Latent contract-mirror fork sentinel in pi-shape-system-prompt.txt" \
    "$CODEGEN_DIR/harnesses/pi/pi-shape-system-prompt.txt" \
    "$SENTINEL6"

assert_contains \
    "Latent contract-mirror fork sentinel in ready.md.j2" \
    "$CODEGEN_DIR/harnesses/claude/commands/ready.md.j2" \
    "$SENTINEL6"

# ── Tests 25-26: fail-loud sentinel in source rule + wired into a template ─────
assert_contains \
    "fail-loud sentinel in _core/fail-loud.md source rule" \
    "$CODEGEN_DIR/shared/rules/_core/fail-loud.md" \
    "$SENTINEL7"

assert_contains \
    "fail-loud include wired into _phoenix_developer_common.md.j2" \
    "$CODEGEN_DIR/shared/subagents/_phoenix_developer_common.md.j2" \
    "{% include 'rules/_core/fail-loud.md' %}"

# Tests 27-28: tailwind.md deep-dive rule wired into developer-static + source carries sentinel
assert_contains \
    "tailwind.md include wired into developer-static.md.j2" \
    "$CODEGEN_DIR/shared/subagents/static/developer-static.md.j2" \
    "{% include 'rules/stacks/static/tailwind.md' %}"

assert_contains \
    "tailwind.md deep-dive sentinel present in stacks/static/tailwind.md source rule" \
    "$CODEGEN_DIR/shared/rules/stacks/static/tailwind.md" \
    "$SENTINEL8"

# ── Tests 28a-28b: NO static planner prompt carries a package.json-gated tailwindcss clause ──
# (mandate: Tailwind v4 always compiled, no package.json detection; regression guard for
#  tailwind-mandate-stated-uniformly — the stale gate must not silently reappear)
assert_absent \
    "no package.json-gated tailwindcss clause in planner-static.md.j2" \
    "$CODEGEN_DIR/shared/subagents/static/planner-static.md.j2" \
    "detected in \`package.json\`, name \`stacks/static/tailwind.md\`"
assert_absent \
    "no package.json-gated tailwind path-pass in stacks/static/planner.md" \
    "$CODEGEN_DIR/shared/rules/stacks/static/planner.md" \
    "names \`stacks/static/tailwind.md\` in dev delegation prompt"

# ── Tests 29-32: context-claim ≠ provenance proof sentinel in shape prompts + sources ──
assert_contains \
    "context-claim≠proof sentinel in claude-shape-system-prompt.txt" \
    "$CODEGEN_DIR/harnesses/claude/claude-shape-system-prompt.txt" \
    "$SENTINEL9"

assert_contains \
    "context-claim≠proof sentinel in pi-shape-system-prompt.txt" \
    "$CODEGEN_DIR/harnesses/pi/pi-shape-system-prompt.txt" \
    "$SENTINEL9"

assert_contains \
    "context-claim≠proof sentinel in shape.txt source" \
    "$CODEGEN_DIR/harnesses/shared/prompt-bodies/shape.txt" \
    "$SENTINEL9"

assert_contains \
    "edit-target provenance FORBIDDEN in planner.md source" \
    "$CODEGEN_DIR/shared/rules/roles/planner.md" \
    "$SENTINEL9_PLANNER"

SENTINEL10="Runtime-path fidelity"
assert_contains \
    "Runtime-path fidelity sentinel in claude-shape-system-prompt.txt" \
    "$CODEGEN_DIR/harnesses/claude/claude-shape-system-prompt.txt" \
    "$SENTINEL10"
assert_contains \
    "Runtime-path fidelity sentinel in pi-shape-system-prompt.txt" \
    "$CODEGEN_DIR/harnesses/pi/pi-shape-system-prompt.txt" \
    "$SENTINEL10"

SENTINEL11="User-facing surface removal/change without operator sign-off"
assert_contains \
    "operator-surface sentinel in claude-shape-system-prompt.txt" \
    "$CODEGEN_DIR/harnesses/claude/claude-shape-system-prompt.txt" \
    "$SENTINEL11"
assert_contains \
    "operator-surface sentinel in pi-shape-system-prompt.txt" \
    "$CODEGEN_DIR/harnesses/pi/pi-shape-system-prompt.txt" \
    "$SENTINEL11"
assert_contains \
    "operator-surface sentinel in ready.md.j2" \
    "$CODEGEN_DIR/harnesses/claude/commands/ready.md.j2" \
    "$SENTINEL11"

SENTINEL12="New-producer / existing-convention reconciliation"
assert_contains \
    "new-producer reconciliation sentinel in claude-shape-system-prompt.txt" \
    "$CODEGEN_DIR/harnesses/claude/claude-shape-system-prompt.txt" \
    "$SENTINEL12"
assert_contains \
    "new-producer reconciliation sentinel in pi-shape-system-prompt.txt" \
    "$CODEGEN_DIR/harnesses/pi/pi-shape-system-prompt.txt" \
    "$SENTINEL12"

# Tests 33-34: reviewer-static eager stack includes (vite + tailwind)
assert_contains \
    "vite.md include wired into reviewer-static.md.j2" \
    "$CODEGEN_DIR/shared/subagents/static/reviewer-static.md.j2" \
    "{% include 'rules/stacks/static/vite.md' %}"
assert_contains \
    "tailwind.md include wired into reviewer-static.md.j2" \
    "$CODEGEN_DIR/shared/subagents/static/reviewer-static.md.j2" \
    "{% include 'rules/stacks/static/tailwind.md' %}"

SENTINEL13="CONTRACT-DECLARATION-SITE COMPLETENESS:"
assert_contains \
    "contract-declaration-site sentinel in claude-shape-system-prompt.txt" \
    "$CODEGEN_DIR/harnesses/claude/claude-shape-system-prompt.txt" \
    "$SENTINEL13"
assert_contains \
    "contract-declaration-site sentinel in pi-shape-system-prompt.txt" \
    "$CODEGEN_DIR/harnesses/pi/pi-shape-system-prompt.txt" \
    "$SENTINEL13"
assert_contains \
    "contract-declaration-site sentinel in ready.md.j2" \
    "$CODEGEN_DIR/harnesses/claude/commands/ready.md.j2" \
    "$SENTINEL13"

SENTINEL15="CAPABILITY-REMOVAL REACHABILITY:"
assert_contains \
    "capability-removal-reachability sentinel in claude-shape-system-prompt.txt" \
    "$CODEGEN_DIR/harnesses/claude/claude-shape-system-prompt.txt" \
    "$SENTINEL15"
assert_contains \
    "capability-removal-reachability sentinel in pi-shape-system-prompt.txt" \
    "$CODEGEN_DIR/harnesses/pi/pi-shape-system-prompt.txt" \
    "$SENTINEL15"
assert_contains \
    "capability-removal-reachability sentinel in ready.md.j2" \
    "$CODEGEN_DIR/harnesses/claude/commands/ready.md.j2" \
    "$SENTINEL15"

SENTINEL_DEADCODE="Dead-code retention / soft-deprecation"
assert_contains \
    "dead-code-retention sentinel in claude-shape-system-prompt.txt" \
    "$CODEGEN_DIR/harnesses/claude/claude-shape-system-prompt.txt" \
    "$SENTINEL_DEADCODE"
assert_contains \
    "dead-code-retention sentinel in pi-shape-system-prompt.txt" \
    "$CODEGEN_DIR/harnesses/pi/pi-shape-system-prompt.txt" \
    "$SENTINEL_DEADCODE"

SENTINEL_PUSHBACK="Concede in ≤1 sentence"

# ── Test: Under Pushback / When Wrong sentinel in remaining claude modes ──────
# NOTE: "build" mode excluded — its self-orchestrating system prompt was
# deleted when the legacy build engine was consolidated onto the Elixir loop
# (see harnesses/shared/prompt-bodies/build.txt deletion). The Elixir loop's
# role prompts carry their own pushback discipline via shared/rules includes,
# not this generated tools-header-based file.
for mode in debug shape experiment ops; do
    assert_contains \
        "pushback sentinel in claude-${mode}-system-prompt.txt" \
        "$CODEGEN_DIR/harnesses/claude/claude-${mode}-system-prompt.txt" \
        "$SENTINEL_PUSHBACK"
done

# ── Test: Under Pushback / When Wrong sentinel in remaining pi modes ─────────
for mode in debug shape experiment ops; do
    assert_contains \
        "pushback sentinel in pi-${mode}-system-prompt.txt" \
        "$CODEGEN_DIR/harnesses/pi/pi-${mode}-system-prompt.txt" \
        "$SENTINEL_PUSHBACK"
done

# ── Test: Incomplete-replacement blocker sentinel across shape prompts + /ready ──
SENTINEL_INCOMPLETE_REPLACEMENT="Incomplete replacement (dropped functionality / unwired new code)"
assert_contains \
    "incomplete-replacement sentinel in claude-shape-system-prompt.txt" \
    "$CODEGEN_DIR/harnesses/claude/claude-shape-system-prompt.txt" \
    "$SENTINEL_INCOMPLETE_REPLACEMENT"
assert_contains \
    "incomplete-replacement sentinel in pi-shape-system-prompt.txt" \
    "$CODEGEN_DIR/harnesses/pi/pi-shape-system-prompt.txt" \
    "$SENTINEL_INCOMPLETE_REPLACEMENT"
assert_contains \
    "incomplete-replacement sentinel in ready.md.j2" \
    "$CODEGEN_DIR/harnesses/claude/commands/ready.md.j2" \
    "$SENTINEL_INCOMPLETE_REPLACEMENT"

SENTINEL_EMPIRICAL_USAGE="Empirical-usage-grounding"
assert_contains \
    "empirical-usage-grounding sentinel in claude-shape-system-prompt.txt" \
    "$CODEGEN_DIR/harnesses/claude/claude-shape-system-prompt.txt" \
    "$SENTINEL_EMPIRICAL_USAGE"
assert_contains \
    "empirical-usage-grounding sentinel in pi-shape-system-prompt.txt" \
    "$CODEGEN_DIR/harnesses/pi/pi-shape-system-prompt.txt" \
    "$SENTINEL_EMPIRICAL_USAGE"
assert_contains \
    "empirical-usage-grounding sentinel in ready.md.j2" \
    "$CODEGEN_DIR/harnesses/claude/commands/ready.md.j2" \
    "$SENTINEL_EMPIRICAL_USAGE"

SENTINEL_SILENT_FAILURE="Silent-failure / fail-open design"
assert_contains \
    "silent-failure blocker sentinel in claude-shape-system-prompt.txt" \
    "$CODEGEN_DIR/harnesses/claude/claude-shape-system-prompt.txt" \
    "$SENTINEL_SILENT_FAILURE"
assert_contains \
    "silent-failure blocker sentinel in pi-shape-system-prompt.txt" \
    "$CODEGEN_DIR/harnesses/pi/pi-shape-system-prompt.txt" \
    "$SENTINEL_SILENT_FAILURE"

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
