# Opus continuation audit

## Invocation and boundary

The Shaper requested this external audit. It ran with `claude -p --dangerously-skip-permissions --model opus --effort medium` under an explicit read-only prompt. The prompt prohibited edits, tests, verification targets, provider-backed targets, approval, and scope decisions. Claude reported using only read commands and parsers; repository status after the run showed no auditor-authored maintained-source change. Its SessionEnd hook reported a missing token after the audit response; the Claude process nevertheless exited successfully, and that hook error supplies no readiness evidence.

## Verdict returned

`NOT_READY` with one blocking Draft-wording defect; path lists were correct.

The audit found that `test/kogen/core_integrity_test.exs` was correctly added to guarded paths and to the offline/affected proof for `exact-candidate-routing` and `failure-preservation-cleanup`. It agreed that mirroring a Candidate-created dangling Complete symlink into control would contradict the ownership boundary. It also found the Draft honestly pending fresh approval and the original `shaping` and `shaped_against` provenance preserved.

The blocker was that the reconciliation requirement existed only in `INTENT.md` and `evidence/failed-build-reconciliation.md`, not in normative scenario acceptance. A plausible implementation could therefore delete or invert the historical assertion, pass the gate, and lose the guard-violation control. The audit required `failure-preservation-cleanup` to state that:

- the dangling `.kogen/intents/complete/<slug>` artifact is observed at the Candidate-owned path;
- the out-of-guard diagnostic still stops the Build;
- the control checkout has no corresponding entry or fake-harness/build-lock residue; and
- neither weakening/removing the control nor mirroring Candidate writes into control is acceptable.

Those requirements were incorporated into `scenarios.yaml` after the audit. No scenario ID, verification target, appetite, or public behavior changed.

## Nonblocking findings

- Earlier `Kogen.GitTest`, `Kogen.ScenarioTrackingTest`, and `stale_verification_record` failures disappeared in later cycles after changes to already guarded implementation paths; the audit found no additional omitted path from them.
- Every test module named by failures across the inspected receipts was either guarded/affected or repairable through already guarded production code.
- `test/kogen/settlement_regression_test.exs` and `test/kogen/codex_public_tasks_test.exs` may expose similar control-to-Candidate fixture assumptions in another Build, but both are already guarded and affected, so this is Developer convergence risk rather than a Draft blocker.
- All 25 dirty or untracked failed-Candidate paths observed by the audit were guarded. `.codex/**` remained outside guarded and affected paths.

## Read scope and limitations

The audit read `README.md`, the maintained Draft, the two supplied failed tracking records, `test/kogen/core_integrity_test.exs`, and targeted current diff/source portions. It reported mechanically comparing guarded, offline, affected, and dirty path sets. It inspected the first receipt of each verification cycle and extracted failures rather than reviewing every receipt byte, and it did not review the full Candidate implementation for correctness. It ran no verification, so its result is shaping analysis rather than Build readiness evidence.
