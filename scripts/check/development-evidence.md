# Offline check development evidence

This is a focused development receipt, not a Kogen Verification Record. The Stop
hook remains the owner of the complete gate; its log is the timing authority.

## Current integration receipt

Re-inspected the preserved candidate against the entire revised Approved package.
All 29 maintained test modules remain explicitly async. The complete selection is
expected to be 116 offline cases and four live-tagged cases (three provider cases
and the outer-owned cold-cache driver); no retained case was removed.

The live audit now requires the current Check to equal the last history record,
rejects numeric-prefix matches for the one-resumption count, and has an explicit
replacement-Developer negative control. Its timestamp control keeps current
record/history consistent so it specifically tests cross-turn ordering.

Before these last audit additions, the 17-case audit/role/lifecycle/settlement/
isolation/cleanup group passed at seed 273705 in 3.3 seconds and 631822 in 2.9.
After the additions, all 13 audit/role/lifecycle/settlement cases passed at seeds
101 (2.1 seconds) and 202 (1.9 seconds). Both successful lifecycle runs assert one
Reviewer resumption; the private legacy negative control reproduces two.
The 17-case Check/settlement/policy/Boundary/private-dependency group passed at
seed 631822 in 1.5 seconds, including concurrent fresh yamerl compilation.
These are focused ExUnit times, not complete gate timing or final acceptance.

Setup cleanup now distinguishes the unowned temporary root before successful
supervisor launch from the supervisor-owned root afterward. Bootstrap cleanup is
registered immediately after creating its support directory. An invalid timeout argument
negative control proves setup failure propagates and leaves no private root.
After integration, all 17 audit/isolation/cleanup cases passed at seed 631822
in 2.9 seconds, including child failure and cancellation cleanup controls.
A follow-up invalid-cwd probe showed that Port.open can succeed before the OS
launcher fails. The supervisor now marks ownership before launching any child;
after confirmed launcher exit the parent reclaims an unmarked root. The added
invalid-cwd regression and integrated audit/isolation/cleanup group passed all
18 cases at seed 631822 in 3.1 seconds. This retains the existing requirement
that started supervisors finish child cleanup before fixture deletion.
Complete warm Check, cold offline acceptance, and provider results remain owned
by Kogen; no gate or Verification Record was manually produced in this integration.

## Reviewer cleanup correction

Removed `ignore_errors=True` from the isolated supervisor's final directory
deletion. An `OSError` now raises a diagnostic with the private path and original
filesystem error, producing a nonzero supervisor exit. The new negative control
runs an otherwise-passing child that creates a non-writable directory containing
a file; it verifies the passing child summary, failing supervisor status, deletion
diagnostic and surviving file. The outer teardown restores permissions and
removes the fixture. This fails against the former error-suppressing deletion.
The focused isolation/cleanup group passed seven cases at seed 631822 in 3.2
seconds. Expected complete selection is now 111 offline cases and four excluded
live cases; the normal owners retain gate responsibility.

## Revised Intent, September 9

The sections below retain historical development receipts. Their former hard
timing thresholds are superseded by the revised Approved Intent: approximately
ten seconds is a guideline, and elapsed time no longer changes the gate status.
No historical pass verifies the revised candidate.

The outer live owner now has a cold-cache acceptance case, excluded from the
offline suite to prevent recursion. It retains conditions and the entire complete
gate log in its own evidence directory. It has not been run by the Developer.

The retained lifecycle, causal settlement, terminal-role, isolation and cleanup
group passed ten cases at each fixed seed 273705 (3.2 seconds), 631822 (2.5),
101 (2.5), and 202 (2.6). These are focused ExUnit times, not full-command gate times.
The successful public lifecycle requires exactly one outer Reviewer resumption;
the legacy negative control still proves the causal two-resumption failure.

The focused Check, settlement, verification-policy and Boundary negative-control
group also passed all 16 cases at seed 631822 (1.1 seconds). All 28 maintained
test modules explicitly enable async execution, including the new audit and
cold-cache modules. The three existing provider cases are retained; the cold
acceptance case is a fourth live-tagged case.

The new protocol audit uses archived checked Git trees to prove initial omission,
ordered raw stream captures to prove the exact resume between independent
Reviewers, and current Check/Commit contents to bind the final bytes. The nested
Reviewer is explicitly relieved of auditing inaccessible historical records.
All six focused audit cases passed after integration at seed 631822 (1.2 seconds),
including a positive control and five missing/misordered-evidence controls.
Expected complete offline selection is now 109 cases, with four live-tagged cases
excluded. Final warm, cold and provider acceptance still belongs to the owners.

## Declared-live cold-cache correction

The owner-run cold log at
`.kogen/runtime/live-evidence/cold-offline-67764-7366/cold-check.log` reports
`warm=False` and fails while compiling yamerl with missing include headers.
Its source path resolves through the shared repository dependency symlink.
The concurrently compiling live fixtures shared that source tree despite having
private `MIX_BUILD_PATH` values. This was an isolation concern, but the focused
probe subsequently reproduced missing headers even with private source copies:
an absolute temporary `MIX_BUILD_PATH` failed, while a fixture-relative path
passed. macOS exposes the same temporary tree as `/var` and `/private/var`;
resolving the build path in the child avoids those differing path spellings.

Cold and compiling live fixtures now copy installed dependency sources privately,
excluding `_build`, `ebin` and `.git`, while retaining headers. The complete cold
gate remains outer-owned and has not been rerun by the Developer. A helper's
initial focused `mix deps.compile yamerl --force --quiet` probe ran at the repository root
and may have refreshed its ignored dependency build cache; subsequent compiler
probes use disposable private copies only. No gate or Verification Record was
manually invoked or written.

The cold owner explicitly sets `MIX_BUILD_PATH=_build/cold` relative to its
private child cwd; it does not inherit or share the outer cache. The new focused
test compiles yamerl concurrently in two private copies and verifies that changing
one copied header cannot affect its peer or the source. Expected selection is
110 offline cases and four excluded live cases, across 29 async test modules.
After integration, the private dependency compile and six rework audit controls
passed together at seed 631822: seven cases in 1.5 seconds. Both private build
directories contain freshly compiled yamerl BEAM output. This is focused evidence,
not a substitute for the complete owner-run cold gate.

The retained real rework Build in
`shape-to-build-67764-2114-1788969487834248584` completed with one resumption,
an actionable missing-notes finding, and a distinct accepting Reviewer. This
does not turn the failed overall live target into a pass.

## Coverage and implementation

The shaped baseline has 98 cases: 93 ordinary offline, two offline public
Shape/Build cases, and three opt-in live cases. All remain. The Approved-mutation
matrix still has nine cases, Build preconditions still have 20, and core integrity
still has eight. Those matrices now use async parameter instances. Other mutable
cwd/environment cases run their original bodies in individual OS processes.

Added coverage: five isolation/denial/inventory cases and two parameter instances
of the settlement negative control. Expected complete selection: 102 offline
cases, three live cases excluded. All 25 maintained test modules explicitly use
async execution, as does the trusted child probe module. Child completion requires
exactly one selected passing test, not merely a zero-failure summary. Missing
selectors, assertion failures, nonzero exits, lingering subprocesses, and timeouts
have negative controls. A rendezvous proves concurrent children overlap while
cwd, environment and temporary roots remain isolated.

The gate retains format, forced warnings-as-errors compilation, strict Credo,
Boundary's real forbidden-reference negative control, and every former failure,
mutation, approval, publication, provenance and lifecycle category. The public
fake lifecycle now uses current compiled task code in a private fixture with a
bounded real check, instead of cloning and rerunning the aggregate suite.

## Causal resumption diagnosis

The former fake ignored every Stop hook response (`>/dev/null`) and emitted
`turn.completed` even after a blocking corrected Check. The hook intentionally
returns process exit zero for a JSON block. Build then correctly resumes with
`settled Check failure: make check failed: ...`; independent Reviewer rework
consumes the second outer resume.

The deterministic settlement regression injects `corrected-check-negative-control`
on the second real fixture Check. A private legacy-behavior copy reproduces the
exact causal feedback and two resumptions. The corrected fake instead rejects
the unexpected block with the retained reason, launches no Reviewer or resume,
and leaves HEAD unchanged. The ordinary successful lifecycle still requires
exactly one resume, solely for Reviewer rework. No retry or relaxed expectation
is used to make that lifecycle pass.

A retained historical fixture receipt at
`$TMPDIR/kogen-lifecycle-5/.kogen/runtime/verification.json` records a real nested
Check failure at `2026-09-07T03:52:44Z`, session `dev-session-1`: nested Git tests
failed with `gpg: signing failed: Cannot allocate memory`. This demonstrates the
mechanism's real exposure to unrelated nested-suite failures. It is older than
the reported September 9 runs; the exact historical trigger at seed 273705 was
not recovered. The approved evidence reports only a role timeout at seed 631822.

## Focused checks

Machine: macOS, Erlang/OTP 29 (erts 17.0.3), Elixir 1.20.2, installed dependencies
and warm build caches. These are focused ExUnit times, **not full-gate timings**.

- Bounded lifecycle passed reported seeds 273705 and 631822, plus 101 and 202.
  After strict hook-response handling, the lifecycle and both causal regression
  cases passed seed 273705 (three cases, 3.0 seconds).
- Lifecycle, both causal cases and isolation probes passed seed 631822 (seven
  cases, 3.5 seconds, before adding the separate provider-denial assertion).
- Final lifecycle/causal/isolation group passed seed 101 (eight cases, 4.0 seconds).
  The same eight cases passed seed 202 in 3.6 seconds.
- The converted precondition matrix passed all 20 cases at seeds 273705 and
  631822 (2.4 and 2.3 seconds); its previous serial isolated form took 10.5 seconds.
- Core/role/verdict passed ten cases at seed 273705 (2.1 seconds); core alone
  passed eight at 631822 (2.2 seconds). Pipe and PTY probes use the real Harness
  Shaper transport without delivering input or EOF; the PTY fake requires tty stdin.
- The three concurrent mutation/precondition/core matrices passed together:
  37 cases at seed 202 in 6.0 seconds. The split settlement/target cases passed
  all 11 at seeds 273705 and 631822 (2.0 and 2.4 seconds).

Complete warm timing, initially empty-cache offline success, and provider-backed
live verification must come from the normal verification owner. The Developer
did not manually invoke those gates.

The first owned complete test run passed all 102 offline cases (three live cases
excluded), with format, forced compile and strict Credo passing too. It took
14.52 seconds, so the warm budget correctly failed. Scheduling has since been
adjusted to start independent modules alongside parameter matrices, and the
serial settlement checks have been separated into concurrent parameter instances.
The owner must measure that resulting Candidate again; the 14.52-second run is
not acceptance evidence.

A later owned run exposed a supervisor bug: killing Erlang's runtime helper on
normal exit caused crash dumps and I/O contention. Normal shutdown now waits for
test-child cleanup and then lets BEAM stop itself; its final exit status must
match the reported result. Check record/target operations and policy preflight
also now accept explicit internal fixture roots, avoiding 15 unnecessary child
VM launches. Their existing cwd-based callers retain their defaults. The 15
focused cases passed at seed 631822 in 0.7 seconds.

The six independent Git scenarios now also use parameter instances, retaining
their original assertions (six passed at seeds 273705 and 631822 in 0.7/0.9
seconds). ExUnit's default scheduler-based concurrency limit is retained to avoid
oversubscribing VM startup. The cleanup regression now independently checks an
immediate timeout and cancels an owner only after its subprocess has started;
five isolation tests passed at the formerly failing seed 719385 in 1.9 seconds.

Further setup optimization compiles isolation support once per invocation and
prepares the precondition Git baseline once, with private child copies. On this
machine 20 `/usr/bin/git --version` launches took 0.227 seconds, versus 0.080 for
the installed Git resolved by `xcrun --find git`. The recipe now resolves that
executable once through a dedicated argument-preserving shim; Python and other
tool resolution are unchanged. These microbenchmarks do not replace full timing.

The next owned run passed all 102 offline cases plus formatting, forced compile,
and strict Credo in 10.39 seconds (seed 444789), still correctly rejected by the
budget. Formatting and compilation now overlap without shared writable outputs.
The two new settlement-only controls begin from a fixture Approved package;
the original full public Shape/approval/Build lifecycle remains unchanged.


Declared-live rework (2026-09-09): the owned Check at seed 539863 passed
102 offline cases, but `/usr/bin/time` reported 10.01 seconds (the Python
stages reported 9.961). This is not under-ten-second acceptance evidence.
The internal warm limit now reserves 0.2 seconds for interpreter startup and
exit; the externally measured complete command remains authoritative. The
Boundary fixture uses two Erlang schedulers instead of each compiler process
starting a full-machine scheduler pool. Its two real compiler assertions passed
in a focused run at seed 539863 (1.0 seconds).

The subsequent owned live run passed the primitives case and failed both
lifecycle cases. Retained evidence is under `.kogen/runtime/live-evidence/`
`shape-to-build-59794-5188-1788964379002655375` and
`shape-to-build-59794-1993-1788964643940024015`. In the first, all three real
Reviewers rejected a shaped fixture contract requiring the secret in the hook
block message and Developer-owned transcript artifacts. The actual hook names
a diagnostic log, and the test driver retains transcripts outside the fixture.
The scripted shaping input now describes that existing protocol and ownership
accurately; real Shape, approval, failure-before-success, zero outer resumes,
and accepting Review/Commit assertions remain intact.

The second Build completed with one Reviewer resumption, but its exact-byte
assertion found a missing trailing newline. The fixture scenario now explicitly
requires one LF in both files, and its bounded check compares dummy.txt bytes
against printf output. Both exact-byte assertions remain unchanged. No provider
run or declared gate was launched manually during this rework; the next owned
Check and live runs must establish the result.

The next owned Check (seed 151954) passed 102 tests but took 11.86 seconds
overall. The same focused set of 32 lifecycle, settlement, Approved-mutation,
and precondition cases passed at this seed in 4.3 seconds with 12 concurrent
cases and 7.0 seconds with 24. The default now uses one case per online parent
scheduler (12 here), since each isolated case starts an additional VM. This
caps concurrency without a global fixture lock; the overlap probe remains.
The complete owned gate must measure the resulting Candidate.

Reviewer rework: the last owned warm Check before these corrections passed all
102 offline cases in 8.13 seconds overall (Python stages: 8.085 seconds). This
receipt does not cover the subsequent corrections or an empty build cache.

The terminal probe no longer supplies `KOGEN_ROLE=shaper`; both open-pipe and
PTY runs inherit the hostile role and rely on Harness to override it. The
nonzero-exit regression now starts a real port child before `System.halt(23)`.
An attempted environment-marker scan failed on macOS Apple executables and was
removed. A small macOS native guard now keeps BEAM's forker and ordinary port
children in the supervisor's process group. It is compiled once per test run
with warnings as errors, and isolated VMs use native erlexec to preserve loading.
No provider or production launch configuration is changed.

The supervisor owns directory removal after confirmed group disappearance.
Collection timeout keeps its port open, requests cancellation, and waits for
supervisor exit. A new regression checks a running child is gone, the supervisor
confirmed the directory still existed at that point, and the directory is gone
when collection returns. This adds one offline case (103 offline, three live).

The cold-cache finding remains an owner evidence requirement. No cold Check or
Verification Record has been fabricated or run by the Developer. The normal
owner must retain a complete pass with an initially empty private MIX_BUILD_PATH,
provider denial active, installed dependencies, and no dependency fetching.

Focused role/isolation/public-lifecycle runs passed all eight cases at seeds
273705 (4.6 seconds) and 631822 (4.1 seconds). During development, the latter
exposed macOS EPERM while launchd was reaping an orphan; signal attempts now
allow that transient state, but the unchanged bounded group-disappearance
check must still succeed before fixture removal. These focused receipts do
not replace the new Candidate's complete owned gates.

The owned Check at seed 200499 passed all 103 cases but exceeded the budget
(12.93 seconds overall). The fixed two-second collection regression now has
its own async module and overlaps the other isolation probes; the seven
focused cleanup/isolation/role cases passed at that seed in 2.6 seconds.
A 30-case fixture comparison retained the 12-case concurrency default:
12 completed in 4.5 seconds versus 5.0 at eight. Credo and tests now overlap
after forced compilation, with explicit dev/test environments and separate
default build trees. Explicit MIX_BUILD_PATH runs remain sequential. Both
stage results are awaited and either failure fails the gate.

The next owned Check (seed 206434) passed all 103 cases in 10.31 seconds
overall, still above the limit. Native-guard compilation now overlaps formatting
and application compilation in a fresh gate-owned temporary directory. Its
compiler status is mandatory before tests start; tests use that invocation's
library and the gate removes it afterward. Focused tests still compile their
own guard. No persistent native cache or test-result cache was introduced.
