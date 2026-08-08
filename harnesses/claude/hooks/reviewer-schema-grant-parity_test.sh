#!/bin/bash
# reviewer-schema-grant-parity_test.sh — Move 18 (Fault 13): asserts every
# role the loop invokes with a flag that requires a tool actually holds
# that tool in its grant. Concretely today: `--json-schema` requires
# `StructuredOutput` (an agent's `tools:` frontmatter allowlist gates
# `StructuredOutput`; the `--allowed-tools` CLI flag does NOT — see
# context/subagents.md), and `OrchestrationLoop.reviewer_role?/1` names
# who gets the flag (any role matching `reviewer-*`).
#
# Checked on BOTH sides of the bake so a template edit that skips
# `make install` fails loud here rather than shipping a reviewer that
# cannot satisfy its own schema (see PROJECT_CONTEXT.md / D-49, D-50):
#   1. the TEMPLATE (shared/subagents/{phoenix,static}/reviewer-*.md.j2)
#   2. the INSTALLED agent (~/.claude/agents/reviewer-*.md), when present
#      — absent (never installed on this box) is not a failure, since
#      installation state is machine-local, not a repo-content check.
#
# A `tools:` line found for a reviewer-* agent that omits StructuredOutput
# is a FAIL. Registering a new flag->tool relationship here is required
# when the loop grows a second typed transport; an unrecognized flag is
# out of scope for this guard (it asserts the ONE relationship named
# above, not a general schema).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

pass=0
fail=0

assert_has_structured_output() {
    local desc="$1" file="$2"

    if [ ! -f "$file" ]; then
        # Installed-agent side: absence is a machine-local install-state
        # fact, not a repo-content defect. Skip silently.
        [ -n "${VERBOSE:-}" ] && printf 'SKIP (absent): %s — %s\n' "$desc" "$file"
        return 0
    fi

    local tools_line
    tools_line=$(grep -m1 '^tools:' "$file" || true)

    if [ -z "$tools_line" ]; then
        printf 'FAIL: %s — no `tools:` line found in %s\n' "$desc" "$file"
        fail=$((fail + 1))
        return 0
    fi

    if printf '%s' "$tools_line" | grep -q 'StructuredOutput'; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s — %s\n  tools: line: %s\n' \
            "$desc" "reviewer-* is invoked with --json-schema but tools: omits StructuredOutput" \
            "$tools_line"
        fail=$((fail + 1))
    fi
}

# --- Templates (repo source, always present) ---
assert_has_structured_output \
    "template: shared/subagents/phoenix/reviewer-phoenix.md.j2 grants StructuredOutput" \
    "$REPO_ROOT/shared/subagents/phoenix/reviewer-phoenix.md.j2"

assert_has_structured_output \
    "template: shared/subagents/static/reviewer-static.md.j2 grants StructuredOutput" \
    "$REPO_ROOT/shared/subagents/static/reviewer-static.md.j2"

# --- Installed agents (machine-local; may not exist on a fresh checkout) ---
assert_has_structured_output \
    "installed: ~/.claude/agents/reviewer-phoenix.md grants StructuredOutput" \
    "$HOME/.claude/agents/reviewer-phoenix.md"

assert_has_structured_output \
    "installed: ~/.claude/agents/reviewer-static.md grants StructuredOutput" \
    "$HOME/.claude/agents/reviewer-static.md"

echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
