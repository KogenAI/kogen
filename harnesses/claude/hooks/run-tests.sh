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
# resolve_role() returns empty when CLAUDE_ROLE is unset, so hooks
# take their non-investigative (build-like) path and deny-case tests assert
# correctly. Tests that need a specific role set it per-invocation
# (CLAUDE_ROLE=X bash "$HOOK"), which overrides this unset for that child only.
# unset is safe under set -u (only reads of missing vars error, not unset).
unset CLAUDE_ROLE

# Neutralize an ambient CODEGEN_LOG_PATH pin from the launching (this very)
# dev session. session_log_from_transcript's new step 0 resolves this env var
# BEFORE .active/mtime scans — without unsetting it here, every resolver test
# in this suite would silently resolve to whatever cycle log this live
# session happens to be pinned to, instead of exercising its own fixtures.
unset CODEGEN_LOG_PATH

# Canonical temp paths — one place, not once per test file.
#
# On macOS $TMPDIR is /var/folders/... and /var is a symlink to /private/var.
# Production hooks resolve their inputs through hooks_realpath / `pwd -P`, so a
# hook reports /private/var/folders/... while a test that built its expectation
# from `mktemp -d` holds /var/folders/... — the two never compare equal and the
# test fails for a reason that has nothing to do with the hook. Four test files
# already carry a hand-written `TMP="$(cd "$TMP" && pwd -P)"` for exactly this;
# every one of the ~140 other `mktemp` sites is a fresh chance to forget it.
#
# Exporting a canonical $TMPDIR is NOT sufficient on macOS: bare `mktemp -d`
# ignores TMPDIR entirely (it uses confstr(_CS_DARWIN_USER_TEMP_DIR)) — verified
# on this platform. So the runner puts a `mktemp` shim ahead of the real one on
# PATH that canonicalizes whatever the real mktemp returns. Test authors write
# plain `mktemp -d` and get a symlink-free path automatically; there is nothing
# left to remember, and nothing about production changes — the shim exists only
# inside the test runner.
#
# Conservative by construction: it delegates to the real mktemp, and if
# canonicalization fails for any reason it prints the real mktemp output
# unchanged. A test that installs its own PATH stub dir simply gets the real
# mktemp back, i.e. exactly today's behaviour.
#
# BOUNDARY: the five hook tests harness-parity/prompt-content-parity invoke
# DIRECTLY from the Makefile do not pass through this runner and so do not get
# the shim. They pass today; if one of them ever grows a raw-tmp-path
# comparison, either give it the usual hand-written `pwd -P` or lift this block
# into something both callers share.
if [ -n "${TMPDIR:-}" ] && [ -d "${TMPDIR:-}" ]; then
    TMPDIR="$(cd "$TMPDIR" && pwd -P)"
    export TMPDIR
fi

_canon_mktemp_dir=$(command mktemp -d)
cat >"$_canon_mktemp_dir/mktemp" <<'CANON_MKTEMP'
#!/usr/bin/env bash
# Test-runner mktemp shim: real mktemp, symlink-free output. See run-tests.sh.
real=$(PATH=$(getconf PATH) command mktemp "$@") || exit $?
if [ -d "$real" ]; then
    (cd "$real" 2>/dev/null && pwd -P) || printf '%s\n' "$real"
elif [ -e "$real" ]; then
    d=$(cd "$(dirname "$real")" 2>/dev/null && pwd -P) || d=""
    if [ -n "$d" ]; then printf '%s/%s\n' "$d" "$(basename "$real")"; else printf '%s\n' "$real"; fi
else
    printf '%s\n' "$real"
fi
CANON_MKTEMP
chmod +x "$_canon_mktemp_dir/mktemp"
PATH="$_canon_mktemp_dir:$PATH"
export PATH

# Isolate test suite from the live cycle-state file.
# Production hooks resolve project_dir="${CWD:-${CLAUDE_PROJECT_DIR:-$PWD}}".
# Tests that set an explicit cwd override this; hooks without an explicit cwd
# fall through to this temp dir instead of the real repo root.
_test_project_dir=$(mktemp -d)
export CLAUDE_PROJECT_DIR="$_test_project_dir"
trap 'rm -rf "$_test_project_dir" "${_canon_mktemp_dir:-}"' EXIT

HOOKS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JOBS="${JOBS:-8}"

# Snapshot durable files under live codegen/gate-pending/ BEFORE the run so
# the backstop detects removal/mutation during the run — not just
# cycle-state.json. Ephemeral codegen-invocation.* sentinels are intentionally
# excluded: a concurrent live build may create/remove its own sentinel while
# this suite runs, and the wrapper validates sentinel ownership separately.
# Durable evidence such as gate-result.json, gate-run.log, and queue.lock
# remains checked so codegen-build's old cwd-less cleanup leak stays covered.
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
    local _gate_pending_path _gate_pending_paths_file
    _gate_pending_paths_file=$(mktemp)
    if [ -d "$dir" ]; then
        find "$dir" -maxdepth 1 -type f ! -name 'codegen-invocation.*' -print0 |
            sort -z >"$_gate_pending_paths_file"
        if [ -s "$_gate_pending_paths_file" ]; then
            while IFS= read -r -d '' _gate_pending_path; do
                printf "%s\t%s\n" "$_gate_pending_path" "$(cksum <"$_gate_pending_path")"
            done <"$_gate_pending_paths_file"
        fi
    fi
    rm -f "$_gate_pending_paths_file"
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
if [ -n "${CLAUDE_ROLE:-}" ]; then
    printf 'FAIL: ambient role leaked into make test runner — not hermetic!\n' >&2
    printf '  CLAUDE_ROLE=%s\n' "${CLAUDE_ROLE:-}" >&2
    exit 1
fi

# Strip managed-build env vars so hook tests run in a hermetic environment.
# CODEGEN_BUILD_START_TS (set by dispatch.sh for the live cycle) leaks
# into pre-commit-guard's git-reset-foreign-commit check, causing
# default-env tests (no explicit CODEGEN_BUILD_START_TS override) to
# spuriously deny against the real repo's HEAD commit time. OCG_CODEGEN_DIR
# (set by the launcher that spawned the current agent session, e.g. when this
# suite runs inside a codegen-build-managed dev session) overrides
# claude-build.sh sibling-resolution of codegen-build, causing
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
# Guard empty discovery before piping to xargs: BSD/macOS xargs (unlike GNU's
# -r/--no-run-if-empty, non-portable to BSD) runs the command ONCE on empty
# stdin, invoking `run_one ""` against a nonexistent path. HOOK_TEST_EXCLUDE
# can legitimately drop the discovered set to zero (e.g. a future exclude-all
# invocation), so capture discovery to a NUL-delimited temp file first and
# skip xargs entirely when it is empty, forcing _xargs_rc=0 explicitly
# (matches xargs's own exit code on a population that ran and produced no
# failures). A temp file (not a `$()` variable) is required here: bash
# command substitution cannot hold embedded NUL bytes — captured NUL-joined
# paths silently concatenate with no separator, corrupting every path after
# the first.
_hook_tests_file=$(mktemp)
_discover_hook_tests >"$_hook_tests_file"
if [ ! -s "$_hook_tests_file" ]; then
    _xargs_rc=0
else
    xargs -0 -n1 -P"$JOBS" bash -c 'run_one "$0"' <"$_hook_tests_file"
    _xargs_rc=$?
fi
rm -f "$_hook_tests_file"
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
