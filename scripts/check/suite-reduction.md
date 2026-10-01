# Suite reduction: progress-budget transitions

This bounded reduction combines repeated pure cases in `Kogen.ProgressBudgetTest` around one observable repair-history trajectory. It does not change the Build engine, test runner, harnesses, or provider and process fixtures.

## Baseline and inventory

The source pin is `e1b43716` (tree `3be258e8af74f77c83000f91078f379e6f55664e`), identical to the tree qualified by `integrated-0a316ea5-qualification.json` at `0a316ea5`. That receipt reports 1,857 passed offline tests, 11 excluded live tests, a 255.643 s test stage, 251.6 s ExUnit duration, 11.817 s inventory setup, and a 275.775 s whole gate. These timings are historical diagnostics; this reduction did not rerun the full gate.

The receipt's slowest individual cases were `DeveloperGuardRebindTest` (67.908 s), `LifecycleTest` (41.169 s), `DeveloperTimeBoxTest` (32.570 s), `HarnessRoleTest` (28.780 s), `ShapeTaskTest` (22.339 s), `ScenarioLifecycleTest` (22.031 s), `ColdOfflineTest` (21.853 s), and `ShapingEvaluationTest` (19.949 s). The largest summed module durations were `BuildPreconditionsTest` (350 cases; 628.425 s), `GitTest` (42; 120.526 s), `ControllerHandoffTest` (46; 112.046 s), `ShapeTaskTest` (19; 107.044 s), and `BuildWorkspaceTest` (39; 105.951 s). Those process, harness, and shaping paths remain outside this unit's ownership.

Tracked `.ex`, `.exs`, `.py`, `.c`, `.h`, and `.sh` test and test-support source under `test/` totals 212 files and 73,491 physical lines at baseline. `ProgressBudgetTest` had 17 cases and 195 physical lines.

## Reduced behavior

The former one-round cases separately checked the free baseline, ordinary clearing, a returning signature, persistence without a repeat charge, and counters surviving resolution. One six-round trajectory now checks those transitions together, including an out-of-order duplicate input, a returning finding while another finding clears, persistence without a duplicate charge, full resolution without refund, and a later return reaching the frozen stop limit. The separate same-tree Review case was removed because the retained stop-boundary case already checks its reason and refusal when that round also clears a finding.

No cases were excluded or renamed. The group now has 12 cases and 169 physical lines. The corresponding routine suite count is 1,852 passed tests, assuming the five retired cases are the only inventory change. Tracked test and test-support source is 212 files and 73,465 physical lines, a reduction of 26 lines.

## Sensitivity controls

Temporary changes to `lib/kogen/build/progress.ex` were made only in this worktree and restored before delivery. The reduced group was run with `MIX_ENV=test mix test test/kogen/progress_budget_test.exs --warnings-as-errors --seed 1` for each control.

| Control | Temporary behavior | Result |
| --- | --- | --- |
| Seeded defect | Charge a signature on every appearance after it has ever been cleared, even when it persisted from the preceding round. | Failed: 11 passed, 1 failed; 1.07 s wall. The returned `a` was charged again while it persisted as another finding cleared, causing an early stop. |
| Plausible wrong fix | Treat any cleared signature as progress even when a different cleared signature returns in the same round. | Failed: 10 passed, 2 failed; 0.98 s wall. The trajectory missed its required oscillation charge; the stop-boundary control also missed its expected stop. |
| Lawful alternate | Compute prior and cleared membership with `MapSet` while retaining the same transition rules. | Passed: 12 passed; 0.91 s wall. |

The defect and wrong-fix runs verify that the shorter group still distinguishes correct accounting from two tempting regressions. The MapSet run checks an equivalent implementation with different internals; no product-source change remains.

## Focused checks and limits

On the restored source, the selected command passed all 12 tests in 0.07 s of ExUnit time (0.91 s wall time, including compilation). `mix format --check-formatted test/kogen/progress_budget_test.exs` passed in 0.22 s. `mix credo --strict test/kogen/progress_budget_test.exs` passed 69 checks on one file in 0.48 s. The first focused test run compiled 78 files and took 2.60 s wall time. No full gate or unrelated tests were run.

This pure group contributes negligible time beside the receipt's process-heavy cases; the case and line reductions are measured, while any whole-gate time change remains unmeasured. After this commit becomes the admission `HEAD`, a future full gate will enumerate the reduced inventory as its prospective baseline.

## Follow-on: precondition fixture cross-product

This follow-on starts from `3f4f2a29` (the integrated suite reduction plus
current project-command integration). It changes only
`test/kogen/build_preconditions_test.exs` and this report. The qualification
receipt records 350 `BuildPreconditionsTest` cases totaling 628.425 s. At that
source pin, the test file had 1,271 physical lines.

The module applies its 50-entry `@precondition_cases` parameter list to every
test in the module. Only `precondition failures never launch the harness`
consumes those case parameters. The two other precondition checks repeat the
same missing-Keychain and missing-`deps/` setup 50 times apiece. Four route
tests ignore the matrix parameters and use `Kogen.SharedOutcome` to assert the
same fixture outcome each time. The repetition adds isolated child starts and
fixture setup without extending the set of checked states.

Those six independent tests now live in a non-parameterized isolated module;
the 50 admission variants remain unchanged. The combined group therefore goes
from 350 invocations to 56 (50 matrix variants plus six single scenarios), a
reduction of 294 invocations or 84%. All seven source-level test definitions
and their assertions remain; the file grows from 1,271 to 1,296 physical lines
for the sibling module and its small shared fixture API. No case is excluded,
renamed, or weakened.

The first version put the template in a later `setup_all` callback. The
offline gate sets `KOGEN_WARM_POOL=1`, so `Kogen.IsolatedCase` registered its
speculative jobs before that callback and omitted `:template` from the queued
child context. A focused warm-pool run reproduced six `KeyError` failures at
`PreconditionFixture.child_template!/0`. The template now comes from a module
tag, which is present before `Kogen.IsolatedCase` registers those jobs.

Both focused paths pass on the corrected source. The ordinary command
`MIX_ENV=test mix test test/kogen/build_preconditions_test.exs
--warnings-as-errors --seed 1` passed all 56 tests in 20.2 s ExUnit / 21.13 s
wall. The same command with `KOGEN_WARM_POOL=1` passed all 56 in 16.9 s / 17.99
s. `mix format --check-formatted test/kogen/build_preconditions_test.exs`
passed in 0.27 s, and `mix credo --strict
test/kogen/build_preconditions_test.exs` passed 69 checks on one file in 0.50
s. `git diff --check` passed. No full gate was run, so the global inventory
and total-gate timing after this integration are not measured. The earlier
ProgressBudget sensitivity controls remain documented above; this follow-on
moves existing checks and introduces no product-code behavior.

## Follow-on: Git publication test cross-product

This unit starts from `24424530`. `test/kogen/git_test.exs` is byte-identical
to the qualified `e1b43716` source, whose receipt records 42 `GitTest` cases
and 120.526 s summed module duration. The module parameterizes seven Git
scenarios across all six tests, but only `preserves Git behavior for each
scenario` reads the `scenario` value. Five focused publication-validation
tests therefore recreate a real temporary Git repository for every unrelated
matrix entry. Two of those tests also allocate 6 MiB payloads.

The five publication tests now run once in `Kogen.GitPublicationTest`. All
seven parameterized scenarios still run unchanged, including the wrong-path
rejection case. The publication checks still allow the previous implementation
and file sizes, reject a non-ignored runtime path, and exclude a file deleted
from the base. The group moves from 42 invocations to 12 (seven matrix cases
plus five single tests), removing 30 repeated invocations. All six source-level
test definitions and assertions remain; the file grows from 331 to 341 lines
for the sibling module and shared test-fixture calls. No case was excluded
or weakened.

Focused ordinary validation ran `MIX_ENV=test mix test
test/kogen/git_test.exs --warnings-as-errors --seed 1`: 12 passed, 3.3 s
ExUnit / 4.69 s wall (including compilation). With `KOGEN_WARM_POOL=1`, the
same focused suite passed 12 tests in 1.7 s ExUnit / 2.35 s wall. `mix format
--check-formatted test/kogen/git_test.exs` passed in 0.23 s, and `mix credo
--strict test/kogen/git_test.exs` passed 69 checks on one file in 0.39 s.
`git diff --check` passed. No full or live gate was run; this measures only
the retained Git test group and does not establish a whole-suite time change.

## Follow-on: settlement ledger no-op matrix

This unit starts at `09bdd28` and changes only
`test/kogen/check_settlement_test.exs` and this report. The seven settlement
records each exercised the meaningful Verification Record assertion and also
reran the same independent ledger test. The ledger test guarded its assertions
with a case-name condition, so six of those seven executions only asserted
`true`.

The seven Verification Record cases remain parameterized and unchanged. The
ledger test now runs once in a separate non-parameterized module. Its five
`Contract.verdict/5` assertions remain intact: acceptance without a ledger in
both supported arities, acceptance with the matching disposition, and rejection
for both ledger mismatches. The group drops from 14 invocations to 8 (seven
settlement checks and one ledger check); both source-level test definitions
remain. The test file shrinks from 169 to 165 lines. No case was excluded or
weakened, and no product code changed.

On the original source, the focused command
`MIX_ENV=test mix test test/kogen/check_settlement_test.exs
--warnings-as-errors --seed 1` passed 14 tests in 0.02 s ExUnit / 0.88 s wall.
With `KOGEN_WARM_POOL=1`, it passed 14 in 0.02 s / 0.66 s. On the reduced
source, the same ordinary command passed 8 in 0.01 s / 0.76 s; the warm-pool
command passed 8 in 0.02 s / 0.64 s. These subsecond wall timings are noisy and
do not establish a suite speedup; the measured reduction is six redundant
invocations.

`mix format --check-formatted test/kogen/check_settlement_test.exs` passed in
0.22 s wall. `mix credo --strict test/kogen/check_settlement_test.exs` passed
69 checks on one file with no issues in 0.35 s wall, and `git diff --check`
passed. No full or live gate was run.

## Follow-on: Auditor pure and pre-I/O cases

This unit adopts only SR005 from the 13-file B026-v2 packet. Its manifest
checks pass, including recommendation patch SHA-256
`1c5bdbdf0ce8f287be1502470568eee058fcbcb27c35332918c612637f42230a`. The
patch was authored against `e1b43716` (tree
`3be258e8af74f77c83000f91078f379e6f55664e`); this work starts at current
`develop` `e31a1fa2` (tree `3de412f89d927bf8e5f9570702e336fc7211ce81`). The
exact patch applies cleanly there despite later Auditor and test-file edits.
It changes only the two Auditor test files and this report; no Auditor product
source changes remain.

The three `parse_message` cases, `build_findings` bounds case, two prompt
rendering cases, and `:asking` state-gating case move to an async
`ExUnit.Case`. Their test names, bodies and assertions are unchanged. The
original file retains its `Kogen.IsolatedCase` boundary for the remaining I/O,
filesystem and fake-harness tests. Across both files, the seven moved tests
remain seven; source-level test definitions stay at 34 total (34 isolated
before, then 27 isolated plus 7 ordinary). Thus the selected group removes
seven isolated child starts without reducing suite case identity count. The
file path portion of those seven test identities changes. The original file
shrinks from 1,063 to 891 lines and the new file is 189 lines (17 net lines
added for the sibling module and its local helper); the reduction is in
isolated process startup, not source size.

Current-candidate controls used
`KOGEN_WARM_POOL=1 MIX_ENV=test mix test
test/kogen/shaping_audit_auditor_pure_test.exs --warnings-as-errors --seed 0`.
The selected positive and lawful enumerated-last variants each passed 7/7
(0.03 s ExUnit; 0.95 s and 0.96 s wall respectively). The bad first-fence
variant failed the last-fenced-object assertion (6/7 passed, 0.03 s / 0.97 s
wall). The wrong fenced-only variant failed the bare-JSON assertion (6/7,
0.03 s / 0.93 s). Each temporary Auditor source mutation was restored before
the next control; no product diff remains.

Both affected files pass together on the restored current source. The ordinary
command `MIX_ENV=test mix test test/kogen/shaping_audit_auditor_test.exs
test/kogen/shaping_audit_auditor_pure_test.exs --warnings-as-errors --seed 0`
passed 34 tests in 33.4 s ExUnit / 34.36 s wall. With
`KOGEN_WARM_POOL=1`, it passed 34 in 10.8 s / 11.62 s. These runs include all
retained isolated tests and all seven moved tests. They validate the current
selected group, not whole-suite performance. B026-v2's separate
matched sample on the pinned e1 source reports seven supervisor jobs to zero
for these cases, and targeted mean wall 4.876 s to 0.920 s; those are packet
observations, not a current-develop performance remeasurement.

`mix format --check-formatted test/kogen/shaping_audit_auditor_test.exs
test/kogen/shaping_audit_auditor_pure_test.exs` passed in 0.21 s wall.
`mix credo --strict test/kogen/shaping_audit_auditor_test.exs
test/kogen/shaping_audit_auditor_pure_test.exs` passed 69 checks on two files
in 0.38 s wall, with no issues; `git diff --check` passed.

The current in-repository advisory `priv/kogen/test-reliability.yaml` has no
declaration or maintained-source row for either Auditor test file. The move
therefore changes no row in that file. B026-v2 flags an external frozen test-ID
allowlist/catalogue reconciliation; its contents are not present in this
worktree and remain an integration dependency. No full or live gate was run.
