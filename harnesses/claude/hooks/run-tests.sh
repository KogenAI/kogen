#!/usr/bin/env bash
# run-tests.sh — run every *_test.sh hook unit-test script in parallel.
#
# Each test script is hermetic (own tmp dirs, no shared global state), so xargs
# -P parallelism is safe. Job count caps at 8 to avoid thrashing on smaller
# machines.

set -u

# Neutralize the ambient role inherited from the launching session.
# resolve_role() returns empty when CLAUDE_ROLE/PI_ROLE are unset, so hooks
# take their non-investigative (build-like) path and deny-case tests assert
# correctly. Tests that need a specific role set it per-invocation
# (CLAUDE_ROLE=X bash "$HOOK"), which overrides this unset for that child only.
# unset is safe under set -u (only reads of missing vars error, not unset).
unset CLAUDE_ROLE PI_ROLE

# Isolate test suite from the live cycle-state file.
# Production hooks resolve project_dir="${CWD:-${CLAUDE_PROJECT_DIR:-$PWD}}".
# Tests that set an explicit cwd override this; hooks without an explicit cwd
# fall through to this temp dir instead of the real repo root.
_test_project_dir=$(mktemp -d)
export CLAUDE_PROJECT_DIR="$_test_project_dir"
trap 'rm -rf "$_test_project_dir"' EXIT

HOOKS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JOBS="${JOBS:-8}"

# Snapshot the live cycle-state file BEFORE the run so the backstop can detect
# a WRITE during the run (not mere presence — a real committed cycle leaves the
# file on disk legitimately).
_cs_sig() { if [ -f "$1" ]; then cksum <"$1"; else printf 'absent'; fi; }
_live_cs="${BASH_SOURCE[0]%/harnesses/*}/codegen/gate-pending/cycle-state.json"
_live_cs_before=$(_cs_sig "$_live_cs")

run_one() {
    local t="$1"
    local name
    name="$(basename "$t")"
    local out
    out=$(bash "$t" 2>&1)
    local last
    last=$(printf '%s' "$out" | grep -E "passed, [0-9]+ failed" | tail -1)
    if printf '%s' "$last" | grep -qE "failed [1-9]"; then
        printf 'FAIL: %s — %s\n%s\n' "$name" "$last" "$out"
        return 1
    fi
    if [ -n "${VERBOSE:-}" ]; then
        printf 'ok:   %s — %s\n' "$name" "$last"
    fi
    return 0
}

export -f run_one

# Backstop: assert the runner is role-clean before any test body starts.
# Converts a future mid-runner role re-leak (someone exporting a role above
# this point) into an attributable failure instead of a silent wall of red.
if [ -n "${CLAUDE_ROLE:-}" ] || [ -n "${PI_ROLE:-}" ]; then
    printf 'FAIL: ambient role leaked into make test runner — not hermetic!\n' >&2
    printf '  CLAUDE_ROLE=%s PI_ROLE=%s\n' "${CLAUDE_ROLE:-}" "${PI_ROLE:-}" >&2
    exit 1
fi

find "$HOOKS_DIR" -name '*_test.sh' -type f -print0 |
    xargs -0 -n1 -P"$JOBS" -I{} bash -c 'run_one "$@"' _ {}

# Backstop: fail loudly only if the live cycle-state was MODIFIED during the run.
# A pre-existing committed cycle-state.json is legitimate (before == after);
# only a write during the run indicates isolation leakage.
_live_cs_after=$(_cs_sig "$_live_cs")
if [ "$_live_cs_before" != "$_live_cs_after" ]; then
    printf 'FAIL: live cycle-state.json was modified during make test — isolation leak!\n' >&2
    printf '  before: %s\n' "$_live_cs_before" >&2
    printf '  after:  %s\n' "$_live_cs_after" >&2
    exit 1
fi
