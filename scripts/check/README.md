# Complete offline verification

Start at the repository root with Elixir 1.20 / OTP 29, Git, Make, Python 3, `rsync`,
and macOS Command Line Tools (`xcrun clang`),
and dependencies already installed by `mix deps.get`. The supported timing machine
is the shaping macOS machine; dependency installation is a prerequisite, not a
verification step.

Kogen's Build controller owns verification settlement: after each Developer
turn it runs exactly the targets the Approved Intent lists in `verified_by`
(here `make check` and any selected catalog target) in catalog order as its own
child processes. The Stop scripts act only on an older controller's v1 context.
Developers and helpers use the controller-issued focused proof selectors and
rehearsals as non-gate readiness work; they must not invoke this directory's
recipe as a bypass around gate ownership.
Bounded `verification_retries` applies to failed controller verification: the
controller resumes the same Developer conversation with the failed target's
receipt and log paths. It is distinct from the outer Developer-rework
allowance. Legacy outer-resumption configuration is a transition input only.

The owner invokes `make check`, which runs [offline.py](offline.py) in this order:

1. Check formatting alongside forced application compilation in parallel. Formatting
   only reads sources; compilation owns build output. Wait for both and reject
   either failure. Compilation keeps warnings as errors and Boundary enabled.
   Also compile the native test guard with warnings as errors into a fresh
   private directory; this independent preparation must pass before tests start.
2. Compile and load every non-live test file with warnings as errors, running
   none of them: `mix test --exclude live --warnings-as-errors --exclude test`
   (every real ExUnit test also carries the implicit `:test` tag, so this
   matches and excludes them all instead of running any). This is the
   `TEST_COMPILE_STAGE` stage; it loads all cataloged tests in about a second,
   clean or with a planted warning, and runs before Credo, the full test run
   and rehearsals, so a compile warning in a test file fails `check` within
   seconds instead of only after the whole suite finishes
   (`"Test suite aborted after successful execution due to warnings"`).
   `--only <unused tag>` is not usable here: ExUnit's own "no test was
   executed" message makes it exit 1 even on a clean tree.
3. Run strict Credo and every offline ExUnit case, including public fake Shape/Build and the
   compiler, failure, mutation, provenance, and verification-ownership controls.
   With default paths these overlap using independent dev/test build trees.
   An explicit `MIX_BUILD_PATH` keeps them sequential to avoid shared writes.
   Wait for both and propagate either failure. The test stage runs
   `mix test --exclude live --warnings-as-errors`: excluded live owners are
   still compiled, so a stale call to a removed arity (for example a
   `Kogen.Harness` launch without its launch context) fails `check` instead of
   only warning. This stage keeps the same `--warnings-as-errors` strictness
   as today; stage 2 above does not weaken or replace it.
4. Rehearse every declared `prepare` (`scripts/check/rehearsals.exs`), then run
   the provider-denied fixture-validation stage
   (`mix run scripts/check/fixture_validation.exs`, `FIXTURE_VALIDATION_STAGE`).
   See "Generated-fixture validation" below.

### Generated-fixture validation

Scenario `offline-fixture-validation`. A live target must not discover a
malformed generated fixture after paid dispatch, so `check` generates each
selected target's fixture exactly as the target consumes it, with provider
access denied, and validates the generated inputs through Kogen's own parsers
(`Kogen.FixtureValidation`, `test/support/fixture_validation.ex`: YamlElixir,
`Kogen.Intent.read/2`, `Kogen.Build.Contract.load/2`, JSON, required files,
Makefile targets, README links, input-receipt hashes, Draft provenance and
frozen hashes). Every validation records a deterministic sha256 digest over the
generated input bytes (volatile controller state such as `.git`, `_build`,
`deps` and `.kogen/runtime` excluded), so the bytes a target later consumes can
be compared with the bytes that were validated.

There is no separate suite and no elapsed-time cutoff. Validation runs inside
work `check` already does:

- `live-reviewer-rework`, `live-shaping-quality` and `live-shaping-smoke`
  declare a `prepare`. Their own setup (`Kogen.LiveReviewerReworkFixture.prepare`,
  `driver.py --prepare suite|smoke`) validates every fixture it generates
  (the suite prepare also materializes and validates the inputs of every
  evaluation case without a compile) and appends records to
  `KOGEN_FIXTURE_VALIDATION_RECEIPT`, which `rehearsals.exs` collects per
  controlled prepare (`fixture_validations`). The live owners call the same
  `validate_fixture!`/`validate_generated_fixture` right after generation, so
  the digest is also recorded before dispatch in a real run.
- `live-native` consumes the Codex compatibility fixture, generated by
  `Kogen.Codex.Compatibility.prepare_fixture/2`; the
  `fixture-validation` stage runs that same function under the same denial
  (credentials removed, `claude`/`codex` shims exiting 97,
  `KOGEN_PROVIDERS_DENIED=1`) and validates it. `live-native` and
  `live-shape-to-build` prepare only the pinned managed runtime.

`offline.py` requires (`validate_fixture_proof`) every catalog `prepare` target
to be classified in `PREPARE_FIXTURE_LABELS` (with its expected fixture labels,
each present with a 64-hex digest, denied providers and a nonzero file count)
or `PREPARE_WITHOUT_FIXTURE`, plus the stage's compatibility record. An unlisted
prepare target, a missing label, a missing digest or an open-provider record
fails as `admission-proof-validation`, an offline/prepare failure that never
dispatches a provider. The receipt's `admission_proof.validated_fixtures` lists
`(label, digest)` pairs and its binding carries their count and combined digest.
A prepare that itself attempts a provider launch while denied hits the refusing
shim, exits nonzero with no `KOGEN_PREPARE_RESULT` frame, and is therefore
classified `offline`, never `provider`.

The stage runs standalone: `MIX_BUILD_PATH=<private> mix run
scripts/check/fixture_validation.exs` (no providers, no full suite); a prepare's
validation can be run alone with its catalog argv plus
`KOGEN_PROVIDERS_DENIED=1 KOGEN_FIXTURE_VALIDATION_RECEIPT=<file>` and, for
the scope checks, `KOGEN_PREPARE_FORCE_SCOPE=pass KOGEN_PREPARE_FORCE_TOOLCHAIN=pass`.
Stated gap: `live-shape-to-build` and `live-general` build their fixtures inside
their own live ExUnit bodies, which this stage cannot call; their Approved
package and Shape fixtures are covered only by their existing offline
rehearsals until those tests expose a generator.

The recipe enables Hex offline mode, places the provider-denial shim first on PATH, and stops on any failed
stage (`run_ordered`; no later stage or phase starts once an earlier one fails). Tests are rerun on every invocation. It prints stage times and complete
elapsed time to the owner's log; only a zero exit counts as passing. Installed
dependencies and existing `_build` caches are the warm timing conditions. An owner
can select an initially empty private `MIX_BUILD_PATH` for cold offline validation;
that run includes dependency compilation and is outside the warm timing guideline.
Never run `deps.get` or fetch crates during either measurement.
Elapsed time never changes a successful exit status. Both warm and cold runs
report complete timing; roughly ten seconds is a warm-cache guideline.
On macOS it resolves the installed Git behind Apple's launcher once, preserving
arguments and exit status through a small shim. Other tool resolution is unchanged.

### `KOGEN_FAILURE_SIGNATURE` frame

When a stage fails, offline.py prints exactly one line for that stage:
`KOGEN_FAILURE_SIGNATURE\t{"stage":"<stage>","test_id":"<file:line or null>","assertion":"<line or null>","reproduce":"MIX_ENV=<env> <stage argv>"}`
(a TAB between the tag and the JSON body). `stage` is offline.py's own
internal stage name (for example `test-compile`, `test`, `credo`, `compile`,
`format` or `rehearsals`); `test_id` is the first failing ExUnit test's
`file:line`, or `null` when no ExUnit test header is found; `assertion` is
the first informative reason line after that test's header (parsed past
`Kogen.IsolatedCase`'s wrapper banner to the real reason), or `null`. This is
the same frame contract `lib/kogen/build/failure_signature.ex` documents for
any target: the controller combines a target name with these fields into a
signature, without parsing offline.py or ExUnit output itself. Failing stages
also carry `reproduce`, the stage command prefixed with its `MIX_ENV` (`test`
for `mix test`, `dev` otherwise). The `--signature-frame` replay omits this
field and only replays captured frame data.

The `reproduce` value is copied into the Build's failure signature and the
Developer's `## First failure` handoff block, but it is excluded from the
signature digest. This keeps recurrence detection stable while giving the
Developer the whole stage command at its normal concurrency. The generic
fallback names the command that `make <target>` runs and says that the
controller runs the target after the turn; it never tells the Developer to
run `make <target>` directly.

Another test, or tool, can replay an already-captured log through the same
emitter without running the gate:

```
python3 -B scripts/check/offline.py --signature-frame <stage> < log.txt
```

This reads the log from stdin and prints the `KOGEN_FAILURE_SIGNATURE` line
for `<stage>`.

[Development evidence](development-evidence.md) accounts for retained cases,
the causal resumption regression, and focused measurements. It does not replace
the owner's complete Verification Record.

Mutable cwd/environment cases use `test/support/isolated_case.ex`. Keep new modules
explicitly async, preserve one execution per selected case, use unique fixtures,
and do not add locks or shared writable build paths. The lifecycle fixture loads
current compiled task code and retains its own bounded check; it must not copy the
aggregate recipe. Provider-backed owners remain opt-in under their narrow
targets (`make live-shape-to-build`, `make live-reviewer-rework`,
`make live-general`, `make live-shaping-quality`, or `make live-native`).
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

Readiness-aware isolated cases opt in with a child environment-variable name.
The helper assigns that variable to a fresh marker inside its private root. The
child creates the marker only when its measured workload is running. A monotonic
startup deadline covers marker creation; the collection deadline begins after the
supervisor observes it. Exit before readiness, absent readiness, and timeout after
readiness remain distinct failures. Callers without readiness keep the established
launch-relative collection behavior. In every phase the supervisor settles owned
descendants before successful removal or retains the root with cleanup diagnostics.

The terminal probe applies the same two-phase timing to the actual
`Harness.exec_shaper` fake route in both pipe and PTY modes. Its writer side stays
open while observing completion, so a fake that waits for EOF fails after readiness.
Focused Python controls are reached through `terminal_probe_test.exs`; they also
assert cleanup of real background descendants on successful and exceptional exits.

The outer-owned, diagnostic-only `make cold-offline` target runs the live case in
`ColdOfflineTest`; routine Builds do not select it, and the same file's non-live
cold setup/dependency regression runs inside `check`. The live case it copies current
sources into a disposable tree, copies installed dependency sources, and invokes the
complete offline gate with an initially absent private `MIX_BUILD_PATH`.
The offline recipe excludes every live-tagged case, including this cold driver,
so it cannot recurse. Provider denial stays active. The driver retains complete
output and cache conditions under `KOGEN_LIVE_LOG_DIR` (default
`.kogen/runtime/live-evidence`). This is separate from the bounded fake lifecycle
and warm timing. Missing cold/stage receipts or nonzero exit fail the outer test.
Developers must not invoke this test; it is an owner-run offline acceptance step and
cannot dispatch a provider.
Both the cold and provider-backed compiling fixtures own private dependency
copies as well as private build paths. Rebar writes into dependency source trees,
so sharing a dependency-directory symlink can race even with separate build paths.
The copy helper excludes dependency build caches while retaining source headers.
It rejects every preexisting destination kind before mutation and materializes
valid source links as private regular files and directories. Broken or cyclic
links and other copy errors fail the fixture and remove only the newly created
partial destination.
The cold driver sets a fixture-relative `MIX_BUILD_PATH=_build/cold`, explicitly
overriding inherited build state. This lets Rebar resolve paths from the child's
physical cwd without mixing macOS `/var` and `/private/var` aliases.

The connected public lifecycle and Build-only Reviewer-rework lifecycle live in
separate async modules. `live_scheduling_test.exs` launches two real
`Kogen.IsolatedCase` dispatchers behind a bounded rendezvous, proves ordered and
distinct outputs, propagates an owner failure, checks cleanup, and inspects the
live source layout so a generic concurrency probe cannot mask same-module
serialization.

The live rework fixture's nested Reviewer assesses final bytes and current Check.
The outer test audits prior omission, actionable rework, exact thread resume,
ordered Checks and distinct Reviewers using retained streams and receipts.
Offline negative controls exercise that audit without provider requests.

The former three-call primitive live probe has these replacement owners:

| Former assertion | Current owner |
| --- | --- |
| `turn.completed` and a usage map for every required invocation | `LiveNativeReceiptAudit`, called by both retained lifecycle owners |
| Exact Developer session on resume | Build-only rework lifecycle plus `LiveReworkAudit` stream-order and two-capture checks |
| Developer/Reviewer identity separation and fresh Reviewers | Connected profile/receipt audit and rework receipt identity checks |
| Structured Reviewer candidate, attempt, scenarios, dispositions and findings | Existing Build contract validation plus `LiveReworkAudit` semantic validation |
| Selected profiles and two-resumption configuration | Retained connected, rework, semantic and root-profile audits |

Each live owner writes `native-receipt-summary.json` beside its retained evidence.
It reports invocation count and per-capture usage maps, including captured native
descendants. Usage is not summed across resumed captures because Codex counters
can include prior work; cached input is only a subset and missing usage is
unavailable rather than zero. The suite formatter reports current case and
whole-suite elapsed time. Three standalone provider invocations are structurally
removed, but elapsed improvement is not promised: provider contention and
non-equivalent historical cache conditions prevent an honest speedup claim.

After edits, use focused tests for the affected behavior. Let the normal owner
(the Build controller) capture complete verification timing and run declared
targets. On failure, read the failing stage and child diagnostics named in the
controller's resume message, fix the cause in the same Developer session, and
let the owner retry while its verification allowance remains. Once verification
settles, an invalid handoff or Review finding uses the separate outer allowance
and requires fresh controller verification on resume. Completion requires the
controller-owned warm gate and every target declared by the Approved Intent. The
provider-backed lifecycle owners, `live-shaping-quality`, `live-native`, and
`cold-offline` are separate selections, not components of an aggregate alias.

The lifecycle and first two specialized targets are provider-backed. `check` and
`cold-offline` are provider-denied. The lifecycle targets run on the configured harness
and need network, its installed runtime and Kogen login, `expect`, and `rsync`; `live-shaping-quality` needs the
provider route and maintained evaluation sources; `live-native` needs the pinned
runtime and configured authentication; and `cold-offline` needs installed dependency
sources, `rsync`, and the offline toolchain. The controller runs exactly the
targets the approved scenarios list (Kogen's own contracts list `check` first)
in dependency-valid catalog cost order, reusing only a provider-backed target's
pass on a byte-identical Candidate within one attempt.

`priv/kogen/test-reliability.yaml` is advisory metadata about cataloged tests.
`check` validates only its structure (schema, counts, required fields, valid
dispositions, unique identities, non-aliased evidence roles). Renaming, adding
or removing a test, or moving a cataloged file, never fails `check`: a row whose
declaration, file or witness no longer resolves is only reported as an advisory
(`Kogen.TestReliabilityCatalog.advisories/2`) for Review.
