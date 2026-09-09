# Complete offline verification

Start at the repository root with Elixir 1.20 / OTP 29, Git, Make, Python 3, `rsync`,
and macOS Command Line Tools (`xcrun clang`),
and dependencies already installed by `mix deps.get`. The supported timing machine
is the shaping macOS machine; dependency installation is a prerequisite, not a
verification step.

The Developer Stop hook owns `make check`. Developers and helpers use focused
non-gate tests, such as `mix test test/kogen/git_test.exs`, while editing. Do not
invoke this directory's recipe as a bypass around gate ownership.

The owner invokes `make check`, which runs [offline.py](offline.py) in this order:

1. Check formatting and force application compilation in parallel. Formatting
   only reads sources; compilation owns build output. Wait for both and reject
   either failure. Compilation keeps warnings as errors and Boundary enabled.
   Also compile the native test guard with warnings as errors into a fresh
   private directory; this independent preparation must pass before tests start.
2. Run strict Credo and every offline ExUnit case, including public fake Shape/Build and the
   compiler, failure, mutation, provenance, and verification-ownership controls.
   With default paths these overlap using independent dev/test build trees.
   An explicit `MIX_BUILD_PATH` keeps them sequential to avoid shared writes.
   Wait for both and propagate either failure.

The recipe enables Hex offline mode, places the provider-denial shim first on PATH, and stops on any failed
stage. Tests are rerun on every invocation. It prints stage times and complete
elapsed time to the owner's log; only a zero exit counts as passing. Installed
dependencies and existing `_build` caches are the warm timing conditions. An owner
can select an initially empty private `MIX_BUILD_PATH` for cold offline validation;
that run includes dependency compilation and is outside the warm timing guideline.
Never run `deps.get` during either measurement.
Elapsed time never changes a successful exit status. Both warm and cold runs
report complete timing; roughly ten seconds is a warm-cache guideline.
On macOS it resolves the installed Git behind Apple's launcher once, preserving
arguments and exit status through a small shim. Other tool resolution is unchanged.

[Development evidence](development-evidence.md) accounts for retained cases,
the causal resumption regression, and focused measurements. It does not replace
the owner's complete Verification Record.

Mutable cwd/environment cases use `test/support/isolated_case.ex`. Keep new modules
explicitly async, preserve one execution per selected case, use unique fixtures,
and do not add locks or shared writable build paths. The lifecycle fixture loads
current compiled task code and retains its own bounded check; it must not copy the
aggregate recipe. Both real-provider modules remain opt-in under `make live`.
The isolation helper's BEAM code is compiled once into a private per-run directory;
the precondition matrix copies an immutable committed template into private repos.
Both preparations are rebuilt for each invocation and cleaned after the suite.
The gate prepares a fresh macOS process-group guard alongside compilation and
formatting, then removes it after tests finish. Focused tests compile their own
copy into their private support directory. Isolated VMs launch through native
`erlexec` so shell environment filtering
cannot discard the guard. It prevents BEAM and `erl_child_setup` from detaching
ordinary port children into separate sessions; the Python supervisor keeps its own
session and can reap those children even after an abrupt BEAM exit. This is test
containment for Erlang ports, not a sandbox for programs that deliberately daemonize.
Before supervisor launch, setup failures remove the unowned temporary directory
and preserve the original error. A startup marker distinguishes successful Port
creation from actual supervisor startup: after confirmed launcher exit, the parent
also removes a root whose supervisor never started. Once started, the supervisor
owns removal. Collection
timeout sends cancellation and awaits its exit status; cleanup failure retains the
remaining directory contents and fails the test instead of reporting completion.
Directory-deletion errors propagate with the path and filesystem error even when
the child test passed. A real permission-denied negative control exercises this
case and restores permissions only in the outer test's teardown.

The outer-owned `make live` suite also runs `ColdOfflineTest`: it copies current
sources into a disposable tree, copies installed dependency sources, and invokes the
complete offline gate with an initially absent private `MIX_BUILD_PATH`.
The offline recipe excludes every live-tagged case, including this cold driver,
so it cannot recurse. Provider denial stays active. The driver retains complete
output and cache conditions under `KOGEN_LIVE_LOG_DIR` (default
`.kogen/runtime/live-evidence`). This is separate from the bounded fake lifecycle
and warm timing. Missing cold/stage receipts or nonzero exit fail the outer test.
Developers must not invoke this test; it is an owner-run acceptance step.
Both the cold and provider-backed compiling fixtures own private dependency
copies as well as private build paths. Rebar writes into dependency source trees,
so sharing a dependency-directory symlink can race even with separate build paths.
The copy helper excludes dependency build caches while retaining source headers.
The cold driver sets a fixture-relative `MIX_BUILD_PATH=_build/cold`, explicitly
overriding inherited build state. This lets Rebar resolve paths from the child's
physical cwd without mixing macOS `/var` and `/private/var` aliases.

The live rework fixture's nested Reviewer assesses final bytes and current Check.
The outer test audits prior omission, actionable rework, exact thread resume,
ordered Checks and distinct Reviewers using retained streams and receipts.
Offline negative controls exercise that audit without provider requests.

After edits, use focused tests for the affected behavior. Let the normal owner
capture complete Check timing and run declared live verification. On failure,
read the failing stage and child diagnostics, fix the cause in the same Developer
session, and let the owner rerun. Completion requires a passing complete warm gate
with whole-command timing, cold offline success, retained coverage, and declared
live verification.
