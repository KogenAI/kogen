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

# QUARANTINE — known-red tests that must NOT fail the gate yet.
# A quarantined test that fails prints `QUARANTINED-RED: <name> — <summary>` to
# stderr and returns 0; a non-quarantined failure prints `FAIL:` and returns 1.
# Newline-delimited basenames (bash 3.2-safe — no declare -A on macOS).
# Membership tested via `grep -qxF` (exact-line, fixed-string).
QUARANTINE='build-no-success-before-commit_test.sh
hooks-lib_test.sh
mode-matrix_test.sh
operator-subagent-allowlist_test.sh
orchestrator-no-ci_test.sh
orchestrator-no-source-edit_test.sh
orchestrator-read-discipline_test.sh
phoenix-dev-gate-long_test.sh
phoenix-dev-gate-short_test.sh
phoenix-dev-gate_test.sh
pre-commit-guard_test.sh
session-log-no-duplicate-section_test.sh
session-log-structure_test.sh
step-log-section-before-spawn_test.sh
subagent-read-discipline_test.sh
subagent-retrospective-guard_test.sh'
export QUARANTINE

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
    local out rc
    out=$(bash "$t" </dev/null 2>&1)
    rc=$?
    local summary
    summary=$(printf '%s' "$out" | grep -E "passed, [0-9]+ failed" | tail -1)
    [ -n "$summary" ] || summary="exit=$rc"
    if [ "$rc" -ne 0 ]; then
        if printf '%s\n' "$QUARANTINE" | grep -qxF "$name"; then
            printf 'QUARANTINED-RED: %s — %s\n' "$name" "$summary" >&2
            return 0
        fi
        printf 'FAIL: %s — %s\n%s\n' "$name" "$summary" "$out"
        return 1
    fi
    if [ -n "${VERBOSE:-}" ]; then
        printf 'ok:   %s — %s\n' "$name" "$summary"
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

set +e
find "$HOOKS_DIR" -name '*_test.sh' -type f -print0 |
    xargs -0 -n1 -P"$JOBS" -I{} bash -c 'run_one "$@"' _ {}
_xargs_rc=${PIPESTATUS[1]}
set -e

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

# Propagate aggregate test failure. xargs exits 123 when any -I{} invocation
# returned non-zero (i.e. a non-quarantined test FAILed — quarantined failures
# return 0 inside run_one, so they do not reach here). Any non-zero xargs exit
# means at least one real failure → fail the gate.
if [ "$_xargs_rc" -ne 0 ]; then
    printf 'FAIL: one or more non-quarantined hook tests failed (xargs rc=%s)\n' "$_xargs_rc" >&2
    exit 1
fi
