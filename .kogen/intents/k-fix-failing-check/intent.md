# Allow Builds to repair failing checks

Slug: k-fix-failing-check
Model: .kogen/intents/k-fix-failing-check/model.qnt invariants=SafeLanding seed=17 samples=100 steps=12
Acceptance:
- .kogen/intents/k-fix-failing-check/acceptance.feature
- features/steps/fix_failing_check_steps.js

Replace the startup refusal for ordinary configured-check nonzero exits with a recorded baseline. Run every configured check in order before builder edits, retaining name, command, exit status and output for each; do not stop collecting on an ordinary failed check. Show baseline failures to the user and builder without recommending removal of checks. Actual execution/startup errors, setup failures, interrupts, missing tools and protection failures retain their existing safety semantics.

Baseline failures are diagnostic, never green verification or waivers. Continue through the ordinary builder, complete candidate verification, independent review and exact-final-tree commit gate. Every configured check must pass before landing. If a baseline failure remains or a previously passing check regresses, ordinary red feedback returns to the same builder (or reviewer for reviewer repairs); existing stopping rules apply. Do not introduce retries or limits. Preserve baseline evidence through checkpoints/resume and expose the ordered before/after comparison in retained Build results and human Build output, including stopped Builds. After states distinguish passed, failed and not run; if no post-change result exists say not run, never infer unchanged or green. Include actual statuses and diagnostic output for failures. Independent review receives the baseline and actual final results.

Implement in the existing Build/run/checkpoint/reporting paths, update doctor advice that currently says Build must stop with check_failing, and reconcile AUT-5 and its obsolete tests/spec scenarios. Keep all other safety, verification, review and commit requirements. No changes to project check definitions, no new CLI command or option, no timeout/limit/retry raises. Tests use temporary fixture projects and existing scripted local providers only, on macOS Apple Silicon and Linux x86-64 glibc; no paid/live calls. This is not a fix for the underlying probe-count test.

## Decisions
- A failing configured check may be the purpose of the Intent; allow the builder to start after recording baseline failures. (source: request)
- Every configured check must pass before landing, with independent review still required; unchanged unrelated failures cannot land. (source: answer 1)
- Report all before/after states honestly without check removal or weakening. (source: request)

## Source comparison
- Addressed: request Problem and Need are implemented by baseline collection plus unchanged all-green final gating above and acceptance rows below; the old environment/check_failing startup refusal is superseded only for completed configured checks with nonzero status.
- Addressed: K-PROBE-COUNT-MAC Build 5b141a1d on kogen 5d93641 (30 Oct 2026, MacBook ~06:45Z) failed go-test on TestShapeProbeMinimalEnvironmentWiring, FAIL kogen/shape, because BSD wc -l pads counts. Acceptance requires a portable fixture reproducing padded-zero failure and its repair, not access to the private historical run/log.
- Addressed: K-APPROVE-DEADLINE Build 5885edf8 on Studio was blocked by the same unrelated failure; acceptance explicitly retains that failure while completing the requested unrelated edit and proves no landing. Linux-host workaround is historical evidence, not the solution.
- Addressed: answer 1 supersedes allowing unchanged unrelated baseline failures to land. New regressions remain red even if the originally failing check is repaired.
- Addressed: no new CLI options/commands, limit/timeout/retry increases, supported platforms and fixture-only tests are preserved in scope and test requirements.
- Omitted deliberately: historical remote evidence directories/logs are not executable dependencies; reproduce their stated failure locally. No requested product behavior is omitted.

## Tests
- Repair an already-failing check through real Build and independent review: TestFailingCheckBuildRepair with fixture padded wc count (regression)
- Collect every baseline check in configured order and retain before/after states for user, builder, reviewer, result and resumed checkpoint: TestFailingCheckBuildEvidence (integration)
- Unchanged unrelated baseline failure prevents landing and is not reported green: TestFailingCheckBuildUnrelated (regression)
- Repairing baseline failure cannot hide a new failing formerly-green check: TestFailingCheckBuildRegression (regression)
- Setup/execution/protection errors still stop safely and doctor no longer falsely predicts check_failing: update existing startup and doctor tests (integration)
- Preserve ordinary all-green Build behavior and exact-tree independent review: existing Build and review tests (existing)

The named tests below are implementation-owned Go tests to add under cli/build, using its existing newEnv fixture and real Build entry boundary. They must assert contractual effects, not merely helper behavior. Repair must assert builder invocation, actual check re-execution and pass, independent reviewer invocation/approval, exactly one commit and committed fix. Unrelated and regression cases must assert red feedback, no commit and no false green; end via existing deterministic stop behavior. Evidence must include a first failing check followed by another failing and a passing check, observed in order, plus checkpoint continuation and stopped-result not-run states. Use stable names/statuses/output markers and assert actual retained and displayed values rather than prescribe a new JSON schema. Seed the count fixture with literal padded `       0` so both hosts reproduce the macOS failure; trim it in the scripted repair. Do not depend on this host's wc implementation. Existing useful tests remain, with only obsolete startup-refusal expectations replaced.

## Feasibility
- Quint model typechecked successfully (probe: exit 0, 0.3 s) and ran SafeLanding with TypeScript backend, seed 17, 100 samples, 12 steps (probe: exit 0, 0.3 s). Model abstracts baseline diagnostics; baseline red does not affect commit eligibility, final green and review do.
