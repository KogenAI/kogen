#!/usr/bin/env bash
# run-tests.sh — run every *_test.sh hook unit-test script in parallel.
#
# Each test script is hermetic (own tmp dirs, no shared global state), so xargs
# -P parallelism is safe. Job count caps at 8 to avoid thrashing on smaller
# machines.
#
# Ownership: standalone invocation (no HOOK_TEST_EXCLUDE) always runs the FULL
# discovered population — used by direct diagnostic calls (`bash run-tests.sh`)
# and by `make test-coverage-shell`, which instruments every hook file.
# The aggregate `make test` runner (templates/generator/run-all-tests.sh) sets
# HOOK_TEST_EXCLUDE to a newline-delimited list of exact repo-relative paths
# (rooted at harnesses/claude/hooks/) already owned by a direct Makefile
# caller (harness-parity, prompt-content-parity, tools-header-no-dup), so each
# discovered test executes exactly once per `make test` run instead of twice.

set -u

# Neutralize the ambient role inherited from the launching session.
# resolve_role() returns empty when CLAUDE_ROLE/PI_ROLE are unset, so hooks
# take their non-investigative (build-like) path and deny-case tests assert
# correctly. Tests that need a specific role set it per-invocation
# (CLAUDE_ROLE=X bash "$HOOK"), which overrides this unset for that child only.
# unset is safe under set -u (only reads of missing vars error, not unset).
unset CLAUDE_ROLE PI_ROLE

# Neutralize an ambient CODEGEN_LOG_PATH pin from the launching (this very)
# dev session. session_log_from_transcript's new step 0 resolves this env var
# BEFORE .active/mtime scans — without unsetting it here, every resolver test
# in this suite would silently resolve to whatever cycle log this live
# session happens to be pinned to, instead of exercising its own fixtures.
unset CODEGEN_LOG_PATH

# Isolate test suite from the live cycle-state file.
# Production hooks resolve project_dir="${CWD:-${CLAUDE_PROJECT_DIR:-$PWD}}".
# Tests that set an explicit cwd override this; hooks without an explicit cwd
# fall through to this temp dir instead of the real repo root.
_test_project_dir=$(mktemp -d)
export CLAUDE_PROJECT_DIR="$_test_project_dir"
trap 'rm -rf "$_test_project_dir"' EXIT

HOOKS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JOBS="${JOBS:-8}"

# Snapshot EVERY file under the live codegen/gate-pending/ dir BEFORE the run
# so the backstop can detect any removal or mutation during the run — not
# just cycle-state.json. codegen-build's pi-leg `rm -f` (run against a bare
# --cwd-less invocation) previously deleted gate-result.json out from under a
# live cycle without this suite ever noticing (a file that is already absent
# before AND after silences a presence-only check). Snapshot the whole
# directory's file list + per-file signature so a removal is caught even when
# the removed file was never watched individually.
_cs_sig() { if [ -f "$1" ]; then cksum <"$1"; else printf 'absent'; fi; }
_live_root="$(cd "$HOOKS_DIR/../../.." && pwd)"
_live_gate_pending="$_live_root/codegen/gate-pending"
_live_cs="$_live_gate_pending/cycle-state.json"
_live_cs_before=$(_cs_sig "$_live_cs")
# Source the cycle-state lib so the backstop can read the writer's session_id
# and distinguish a concurrent live self-build (legitimate external write,
# carries a real session_id) from a genuine in-suite isolation leak.
. "$(dirname "${BASH_SOURCE[0]}")/lib/cycle-state.sh"
_live_cs_sid_before=$(cycle_state_session_id "$_live_root")

# Whole-directory snapshot: filename\tsignature per line, sorted, for a stable
# diff-able before/after comparison. Empty/absent dir → empty snapshot.
#
# Avoid `xargs -I{}` here: BSD xargs (macOS) allocates a small fixed
# replacement buffer (-S, default 255 bytes) independent of ARG_MAX, and a
# long absolute path (e.g. a nested .claude/worktrees/<slug>/... checkout)
# can exceed it, failing with "command line cannot be assembled, too long"
# even though the actual argument list is tiny. A plain read loop avoids the
# replsize limit entirely and is portable across GNU/BSD.
_gate_pending_snapshot() {
    local dir="$1"
    local f
    if [ -d "$dir" ]; then
        while IFS= read -r -d '' f; do
            printf '%s\t%s\n' "$f" "$(cksum <"$f")"
        done < <(find "$dir" -maxdepth 1 -type f -print0 | sort -z)
    fi
}
_gate_pending_before=$(_gate_pending_snapshot "$_live_gate_pending")

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

# Strip managed-build env vars so hook tests run in a hermetic environment.
# CODEGEN_BUILD_START_TS (set by dispatch.sh for the live cycle) leaks
# into pre-commit-guard's git-reset-foreign-commit check, causing
# default-env tests (no explicit CODEGEN_BUILD_START_TS override) to
# spuriously deny against the real repo's HEAD commit time. OCG_CODEGEN_DIR
# (set by the launcher that spawned the current agent session, e.g. when this
# suite runs inside a codegen-build-managed dev session) overrides
# claude-build.sh/pi-build.sh sibling-resolution of codegen-build, causing
# portable-launcher_test.sh and worktree-*_test.sh fixtures (which stub a
# sibling codegen-build next to the launcher under test) to silently invoke
# the REAL installed codegen-build instead of the test stub.
unset CODEGEN_BUILD_START_TS OCG_CODEGEN_DIR

# Exact-path exclusion filter, folded into the discovery stage so the
# find|xargs pipeline stays two-stage (PIPESTATUS[1] below still indexes
# xargs). Normalizes each discovered file to "harnesses/claude/hooks/<name>"
# (never a relpath against $PWD — see bash-discipline § symlink portability)
# and drops any exact match against HOOK_TEST_EXCLUDE. Unset/empty ->
# no-op, byte-for-byte today's full-discovery behavior.
_discover_hook_tests() {
    local f rel
    while IFS= read -r -d '' f; do
        rel="harnesses/claude/hooks/$(basename "$f")"
        if [ -n "${HOOK_TEST_EXCLUDE:-}" ] && printf '%s\n' "$HOOK_TEST_EXCLUDE" | grep -qxF "$rel"; then
            continue
        fi
        printf '%s\0' "$f"
    done < <(find "$HOOKS_DIR" -name '*_test.sh' -type f -print0)
}

set +e
_discover_hook_tests |
    xargs -0 -n1 -P"$JOBS" -I{} bash -c 'run_one "$@"' _ {}
_xargs_rc=${PIPESTATUS[1]}
set -e

# Backstop: fail loudly on ANY removal or mutation of a file that was present
# under the live codegen/gate-pending/ before the run. cycle-state.json writes
# carrying a fresh session_id (a concurrent live self-build advancing its own
# state) are the one tolerated exception — warn, don't fail. Every other
# change (including any removal, e.g. of gate-result.json) is an unconditional
# isolation leak.
_gate_pending_after=$(_gate_pending_snapshot "$_live_gate_pending")

if [ "$_gate_pending_before" != "$_gate_pending_after" ]; then
    _live_cs_sid_after=$(cycle_state_session_id "$_live_root")
    _live_cs_after=$(_cs_sig "$_live_cs")

    # Compute the delta with cycle-state.json's legitimate advance excluded,
    # to check whether that is the ONLY change.
    _gate_pending_before_no_cs=$(printf '%s\n' "$_gate_pending_before" | grep -v "^${_live_cs}"$'\t' || true)
    _gate_pending_after_no_cs=$(printf '%s\n' "$_gate_pending_after" | grep -v "^${_live_cs}"$'\t' || true)

    if [ "$_gate_pending_before_no_cs" = "$_gate_pending_after_no_cs" ] &&
        [ "$_live_cs_before" != "$_live_cs_after" ] &&
        [ -n "$_live_cs_sid_after" ] && [ "$_live_cs_sid_after" != "$_live_cs_sid_before" ]; then
        # The ONLY change is cycle-state.json, and it carries a real session_id
        # distinct from the pre-run value (no hook test ever writes a
        # session_id to the REAL repo-root path — every test uses its own temp
        # dir). A concurrent live self-build advanced its own state. Tolerate.
        printf 'WARN: live cycle-state.json advanced during make test (external self-build session=%s) — tolerated, not an isolation leak\n' "$_live_cs_sid_after" >&2
    else
        # Any other change — including a removal of gate-result.json or any
        # other gate-pending file — is attributable to the suite itself. Fail
        # loud and name what changed.
        printf 'FAIL: live codegen/gate-pending/ was modified during make test — isolation leak!\n' >&2
        printf '  before:\n%s\n' "$_gate_pending_before" >&2
        printf '  after:\n%s\n' "$_gate_pending_after" >&2
        exit 1
    fi
fi

# Backstop: a hook test must never write a fixture file INTO the live hooks
# source dir. No legitimate hook is ever a dotfile — every real hook is a
# plain `*.sh`. A stray dotfile here breaks `hook_registrations.py`'s
# HOOK-MANIFEST parity check (`Path.glob("*.sh")` matches dotfiles too) and,
# if the test process is killed before its trap fires, strands the file
# permanently until someone deletes it by hand.
_stranded_fixtures=$(find "$HOOKS_DIR" -maxdepth 1 -name '.*' -type f)
if [ -n "$_stranded_fixtures" ]; then
    printf 'FAIL: STRANDED TEST FIXTURE in harnesses/claude/hooks/: a test wrote a non-hook file into the live hooks dir. Delete it (it will break `make install`), and write fixtures into `mktemp -d` instead.\n' >&2
    printf '%s\n' "$_stranded_fixtures" >&2
    exit 1
fi

# Propagate aggregate test failure. xargs exits 123 when any -I{} invocation
# returned non-zero. Any non-zero xargs exit means at least one real failure
# → fail the gate. The runner fails-closed: no allowlists, no suppression.
if [ "$_xargs_rc" -ne 0 ]; then
    printf 'FAIL: one or more hook tests failed (xargs rc=%s)\n' "$_xargs_rc" >&2
    exit 1
fi
