#!/usr/bin/env bash
# no-role-defers-to-human_test.sh — source-grep guard: lock the invariant that
# no loop role can defer to a human mid-cycle.
#
# Background: `clarifying_question` used to be a dispatcher punctuation
# heuristic (schema-less reply ending in "?" → phantom status), NOT a status
# any role emitted. It has been deleted from both dispatchers and the loop's
# dead consumer branch. This test locks the invariant at its source so the
# heuristic (or an AskUserQuestion grant on a loop role) cannot silently
# return.
#
# Two independent arms:
#   (a) zero `clarifying_question`/`CLARIFYING_QUESTION` tokens in either
#       call-dispatch.sh (the dispatcher that used to mint the phantom status)
#   (b) zero `AskUserQuestion` in any `tools:` frontmatter line under
#       shared/subagents/**/*.md.j2 (no loop role has the tool to ask)
#
# Footer: `Results: N passed, N failed`; exit 1 when any FAIL.

set -euo pipefail

HOOKS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODEGEN_ROOT="$(cd "$HOOKS_DIR/../../.." && pwd)"

pass=0
fail=0

# ── Arm (a): dispatcher source must carry zero phantom-status tokens ─────────
for f in \
    "$CODEGEN_ROOT/harnesses/claude/call-dispatch.sh" \
    "$CODEGEN_ROOT/harnesses/pi/call-dispatch.sh"; do
    hits=0
    hits="$(grep -c "clarifying_question\|CLARIFYING_QUESTION" "$f" 2>/dev/null || true)"
    hits="${hits:-0}"
    if [[ "$hits" -eq 0 ]]; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s carries zero clarifying_question tokens\n' "$f"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s carries %d clarifying_question token(s) — the phantom status heuristic is forbidden (no role can mint it; deleting it fixed a role being wrongly failed for ending a sentence with "?")\n' "$f" "$hits"
        fail=$((fail + 1))
    fi
done

# ── Arm (b): no loop-role agent template grants AskUserQuestion ──────────────
while IFS= read -r tpl; do
    tools_line="$(grep -m1 '^tools:' "$tpl" 2>/dev/null || true)"
    if [[ -z "$tools_line" ]]; then
        # No tools: line at all is a PASS — assert on the grant, not on the
        # line's existence.
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s has no tools: line (no grant possible)\n' "$tpl"
        pass=$((pass + 1))
        continue
    fi
    if [[ "$tools_line" == *"AskUserQuestion"* ]]; then
        printf 'FAIL: %s grants AskUserQuestion — no loop role may defer to a human mid-cycle\n' "$tpl"
        fail=$((fail + 1))
    else
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s does not grant AskUserQuestion\n' "$tpl"
        pass=$((pass + 1))
    fi
done < <(find "$CODEGEN_ROOT/shared/subagents" -name '*.md.j2' -not -name '_*')

printf 'Results: %d passed, %d failed\n' "$pass" "$fail"
if [[ "$fail" -gt 0 ]]; then
    exit 1
fi
exit 0
