#!/usr/bin/env bash
# effort-canonical.sh — single source of truth for the canonical effort
# vocabulary. Sourced (never executed) by codegen-build and codegen-call.
#
# Deliberately EXCLUDES "minimal" — Claude rejects that value at runtime
# (probed live: `claude --effort minimal` warns and silently falls back to
# its own default effort). The canonical set is the intersection any adapter
# can realize deterministically, plus "off" (realized natively per-adapter,
# never via a raw "--effort off"/"--effort minimal" passthrough).
#
# set -uo pipefail (no -e): sourced into callers already under -e; a helper
# function returning non-zero here is a deliberate validation failure, not an
# unexpected error to abort the sourcing shell.
set -uo pipefail

CODEGEN_CANONICAL_EFFORTS="off low medium high xhigh max"

# codegen_validate_effort <value>
# Returns 0 when <value> is a member of CODEGEN_CANONICAL_EFFORTS.
# Returns 2 (and prints a diagnostic to stderr) on any other value, including
# empty string or "minimal".
codegen_validate_effort() {
    local value="${1:-}"
    if printf '%s\n' "$CODEGEN_CANONICAL_EFFORTS" | tr ' ' '\n' | grep -qxF "$value"; then
        return 0
    fi
    printf 'codegen: invalid effort %q; valid: %s\n' "$value" "$CODEGEN_CANONICAL_EFFORTS" >&2
    return 2
}
