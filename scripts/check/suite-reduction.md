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
