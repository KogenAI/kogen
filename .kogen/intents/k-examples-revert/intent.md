# Remove the approval-time example check

Slug: k-examples-revert
Model: not applicable — removes a heuristic gate, with no new state machine
Acceptance:
- .kogen/intents/k-examples-revert/acceptance.feature
- features/steps/k_examples_revert_steps.js

Remove K-SHAPE-ACCEPTANCE-CONTRADICTS (d1ffe29) and the Scenario Outline expansion added solely for that check by K-EXAMPLES-OUTLINE (3ea2e23). Shape must no longer ask a model to derive expected values, emit example_check results or refuse submissions on that basis. Approval card and hash forms must ignore legacy example-contradictions.json records, including matching package hashes. Remove the associated implementation, tests, acceptance steps, fixtures, configuration specific to the removed feature, and documentation text. Do not remove general Gherkin Outline support or skipped-step observations used by normal readiness.

Keep all unrelated changes since those commits, specifically K-ACCEPTANCE-GREEN-SHAPE, K-REVIEW-CATALOG-REPIN, K-PROBE-MIX-HOME and K-ACCEPT-RELEASE-COPY. Preserve normal readiness, accounted-red acknowledgment, step self-check, decision check, provenance and approval protections. No new command, flag, option, timeout, retry or limit change. Do not edit .kogen/project.yaml or protected dependency pins. Historical Intent packages may remain as history; remove their obsolete executable step/fixture support without rewriting protected contracts.

## Decisions
- A format-only difference must not block approval: `"status":0,"out":"61610a0a"` versus `{"status":0,"out":"61610a0a"}`. (source: request)
- Contradictory acceptance (Studio issue 42502600) remains open for a different design measured by research before landing; do not replace this check with another heuristic. (source: request)
- Build this removal with the pre-d1ffe29 release v0.1.0-dev.094415bb, as K-EXAMPLES-OUTLINE was; this is an operator tool prerequisite, not a product version change. (source: request)
- Use one fast deterministic regression, well inside approval's existing 120-second per-step limit and requiring no live model. The complete suite is delivery's measurement after landing, not an added approval gate. (source: request)

## Source comparison
- addressed: request Problem/Need, d1ffe29 and 3ea2e23 removal; outcome paragraphs remove the model check, persisted refusal and check-only expansion, including native and Claude Code paths and obsolete support artifacts.
- addressed: acceptance evidence's exact format-only pair; acceptance.feature preserves both literals and requires a real Shape-to-approval regression with no example_check/examples_contradict. The Go regression runs actual local entry points with scripted provider responses only, not a model.
- addressed: request's preservation of subsequent work and no command/limit changes; outcome boundaries and existing configured checks preserve these. General Outline readiness observations are explicitly not the removed expansion.
- addressed: shc2's 52 paired runs on 1 Nov 2026, net minus 4 hidden passes against bc54c65; Studio 002072a5/framecrc-go, agingq and backoff are motivation, not reproducible fixtures supplied here. The format-only reproduction is the executable case; no invented reproduction of those tasks is required.
- addressed: main ruling of 1 Nov 2026 leaves 42502600 open and requires measurement of a different design; Decisions prohibit a replacement check and preserve that open status.
- superseded: spec/prose/02-shaping.md example-check paragraph and cli/shape/examplecheck_test.go expectations of refusal; remove them rather than preserving their former assertions.
- omitted: no requested product behavior; release selection is a required external Build prerequisite, not something acceptance can authenticate from repository bytes.

## Tests
- Shape submissions proceed without an expected-value model check: add TestExamplesRevertShapeApproval using existing local shape fixtures and scripted provider, exercising Shape's real submission path (regression)
- Card and full-hash approval ignore a matching legacy contradiction record: the same regression invokes Approve, asserts card status and successful approval marker without example refusal (regression)
- Remove check-only expansion and obsolete check support without removing general Outline execution: delete obsolete tests and retain normal readiness/skipped-step tests and configured spec checks (existing)
- Preserve unrelated post-d1ffe29 behavior and checks: run configured checks unchanged; full deterministic suite remains delivery measurement (existing)

The regression TestExamplesRevertShapeApproval belongs in cli/shape and is implementation-owned, not protected acceptance. Use the existing temporary Git/project/provider fixtures. Its package must contain a Scenario Outline with an Examples row using the exact feature literals below. Submit it through Shape with a scripted submission response and, if normal accounted red requires it, exact unchanged acknowledgment. Any attempted submit_example_check provider request must fail the regression rather than receiving a successful fake check. Assert Shape reaches ready, emitted events contain no example_check or submission_refused gate example_check, and no new contradiction record is written. Then create a legacy example-contradictions.json containing the current package hash and a contradiction line; invoke both approval forms through their actual entry points, require the normal card result and successful full-hash approval with a marker. Assert no examples_contradict refusal. Use an ordinary legitimate missing-feature acceptance failure in the inner package, not malformed steps or fixtures. Assert normal readiness actually ran. This single focused test must require no model credentials or network service beyond the local scripted fixture and finish well inside 120 seconds.

## Feasibility
- none
