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
SENTINEL9_DEVELOPER_PROBES="only \`ran:\` against git/fs counts"
SENTINEL10_UNVERIFIED_MECHANISM="the error-path behavior of any mechanism you did not run"
SENTINEL11_ADVISE_UNSURE="Ask a stronger model before you guess"
SENTINEL12_ADVISE_NO_OPPOSITE_PROVIDER="opposite provider"

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

# ── Test 3: INTERACTION-AUDIT sentinel present in claude shape baked prompt ───
assert_contains \
    "INTERACTION-AUDIT sentinel in claude-shape-system-prompt.txt" \
    "$CODEGEN_DIR/harnesses/claude/claude-shape-system-prompt.txt" \
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
    "SWEEP-CLASS COMPLETENESS sentinel in ready.md.j2" \
    "$CODEGEN_DIR/harnesses/claude/commands/ready.md.j2" \
    "$SENTINEL5"

# ── Tests 22-24: Latent contract-mirror fork sentinel in shape prompts + ready ──
assert_contains \
    "Latent contract-mirror fork sentinel in claude-shape-system-prompt.txt" \
    "$CODEGEN_DIR/harnesses/claude/claude-shape-system-prompt.txt" \
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

# ── Tests 29-32: context-claim ≠ provenance proof sentinel in shape prompts + sources ──
assert_contains \
    "context-claim≠proof sentinel in claude-shape-system-prompt.txt" \
    "$CODEGEN_DIR/harnesses/claude/claude-shape-system-prompt.txt" \
    "$SENTINEL9"

assert_contains \
    "context-claim≠proof sentinel in shape.txt source" \
    "$CODEGEN_DIR/harnesses/shared/prompt-bodies/shape.txt" \
    "$SENTINEL9"

assert_contains \
    "edit-target provenance FORBIDDEN in developer.md source" \
    "$CODEGEN_DIR/shared/rules/roles/developer.md" \
    "$SENTINEL9_DEVELOPER_PROBES"

# ── Tests: unverified-mechanism provenance clause + advise semantics ──────────
# "a stuck developer asks before it guesses" — the assumed: forbid extends to
# unverified error-path behavior, and the advise tool/prompt trigger on
# uncertainty rather than repeated failure. No harness runs jq itself, so the
# jq-swallow incident this pitch is about has no direct regression test here
# — this sentinel is the guard against it recurring unverified.
assert_contains \
    "unverified-mechanism FORBIDDEN clause in developer.md source" \
    "$CODEGEN_DIR/shared/rules/roles/developer.md" \
    "$SENTINEL10_UNVERIFIED_MECHANISM"

assert_contains \
    "advise tool description leads with uncertainty, not failure" \
    "$CODEGEN_DIR/harnesses/claude/mcp-server/src/tools.ts" \
    "$SENTINEL11_ADVISE_UNSURE"

assert_absent \
    "advise tool no longer promises an opposite-provider call" \
    "$CODEGEN_DIR/harnesses/claude/mcp-server/src/tools.ts" \
    "$SENTINEL12_ADVISE_NO_OPPOSITE_PROVIDER"

assert_absent \
    "advise-system-prompt.md no longer promises a DIFFERENT provider" \
    "$CODEGEN_DIR/harnesses/claude/advise-system-prompt.md" \
    "DIFFERENT provider"

assert_absent \
    "codegen-advise no longer reports a dormant opposite-provider guard" \
    "$CODEGEN_DIR/codegen-advise" \
    "$SENTINEL12_ADVISE_NO_OPPOSITE_PROVIDER"

for dev_tpl in \
    developer-phoenix-backend.md.j2 \
    developer-phoenix-frontend.md.j2; do
    assert_absent \
        "Stuck-loop escalation block removed from $dev_tpl" \
        "$CODEGEN_DIR/shared/subagents/phoenix/$dev_tpl" \
        "## Stuck-loop escalation"
done

assert_absent \
    "Stuck-loop escalation block removed from developer-static.md.j2" \
    "$CODEGEN_DIR/shared/subagents/static/developer-static.md.j2" \
    "## Stuck-loop escalation"

assert_contains \
    "backend developer prompt still hands back architectural root causes" \
    "$CODEGEN_DIR/shared/subagents/phoenix/developer-phoenix-backend.md.j2" \
    "architectural or design choice"

# Tests 33-34: reviewer-static eager stack includes (vite + tailwind)
assert_contains \
    "vite.md include wired into reviewer-static.md.j2" \
    "$CODEGEN_DIR/shared/subagents/static/reviewer-static.md.j2" \
    "{% include 'rules/stacks/static/vite.md' %}"
assert_contains \
    "tailwind.md include wired into reviewer-static.md.j2" \
    "$CODEGEN_DIR/shared/subagents/static/reviewer-static.md.j2" \
    "{% include 'rules/stacks/static/tailwind.md' %}"

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

# ── Test: the deterministic commit step's staging scope is unconditional
# `git add -A` ──────────────────────────────────────────────────────────────
# The committer ROLE (and its prompt-level "never hand-pick a subset" /
# "Partial snapshots ... are FORBIDDEN" instructions) is gone — commits are
# now made by codegen-commit, a script, which can never choose to stage by
# name: the invariant is enforced structurally (no model in the loop to
# licence a hand-pick), not by prompt wording. See pitch "committing is
# deterministic, not a model call".
assert_absent \
    "codegen-commit carries no stage-by-name hand-pick option" \
    "$CODEGEN_DIR/codegen-commit" \
    "stage by name only"

assert_contains \
    "codegen-commit mandates unconditional git add -A" \
    "$CODEGEN_DIR/codegen-commit" \
    "git -C \"\$CWD\" add -A"

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
