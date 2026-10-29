# Limit ten-minute budgets to Build and Review

Slug: k-shapebudget
Model: not applicable — this corrects client construction constants and logging wiring, not the provider's existing response lifecycle
Acceptance:
- .kogen/intents/k-shapebudget/acceptance.feature
- features/steps/k_pin_knobs_steps.js

Correct K-RESPBUDGET-DEFAULT (e2030bd): native Build and independent Review use a fixed 10-minute provider ResponseBudget set when their clients are constructed/configured. Native Shape, Refine and shape-init leave ResponseBudget zero, using the pinned loop's 30-minute default per logical Respond call. This includes Shape workers. Remove ResponseBudget from internal/research.Current.Client and remove its ApplyClient path (remove an empty ClientSettings/Client container if nothing remains). Update existing tests that drove the research knob to assert the role constants instead. Keep the once-per-run response_budget record, reporting the effective budget, including Shape's actual 30 minutes.

Do not change any other timeout, limit, retry, request payload or transport field. Requests must remain otherwise byte-identical. No command, flag, project.yaml key or research knob is added. Preserve existing provider/unavailable outcomes and the user-facing wording naming 10 minutes for Build/Review expiry. Do not edit cli/third_party/kogen-loop/** or cli/loop-pin.json.

## Decisions
- Build and Review get 10 minutes; Shape, Refine and init keep zero and inherit 30 minutes; there is no knob. (source: request)
- Retain one effective response_budget event per run, not one per provider request; use budget_ms=1800000 for Shape/Refine/init runs where the record applies, and 600000 for Build/Review runs. Preserve the existing event schema and readable duration wording. (source: request)
- The installed research gate is separate: after installation, research runs a Shape cell on gpt-6.1-sol/high with a long request and observes completion. Deterministic acceptance is not live qualification and does not trigger paid calls. (source: request)

## Source comparison
- Addressed: request What to build and 29 Oct 2026 no-knob update are implemented by role constants, zero Shape/Refine/init clients, removal of research budget configuration and effective-budget logging above; executable acceptance invokes the two named contracts below.
- Addressed: Acceptance's 800-second steadily streaming reproducer is TestShapeBudgetStreaming800Seconds; role observations, Build/Review stalls, logging and byte identity are TestShapeBudgetRoleContract. All configured checks remain required.
- Addressed: Must stay and Host safety remain constraints: no protected loop/pin edits, CLI/config additions, other limit/retry changes, process-name kills or synthetic CPU load. Use only temporary fixture directories and stop only processes started by the test.
- Superseded: e2030bd's ten-minute default for all roles and research-knob tests must be updated, not preserved as intended behavior. The request's research evidence (29 Oct 2026: p99 566 s, max 825 s, twelve over 600 s, about 35 tok/s and 17–28k tokens) motivates the supplied 800-second regression, not additional telemetry requirements.
- Omitted intentionally from implementation: request Next's provider_attempt first_byte_ms/max_gap_ms/end_reason instrumentation (ttft_ms currently nil) and proposals/stream-timeouts-2026-10-29.md first-byte 90 s / idle 120 s experiment; those belong in kogen-loop followed by a re-pin, not this Intent. The after-install research gate remains an external gate rather than an automated live test.

## Tests
- Shape streams for 800 simulated seconds and completes without being cut: add TestShapeBudgetStreaming800Seconds in cli/shape using the actual Shape entry and existing fake-provider fixtures, client Now seam and valid streaming events, with no real-time sleep (regression)
- Shape, Refine, init and Shape workers inherit 30 minutes while Build and Review use fixed 10 minutes: add TestShapeBudgetRoleContract in cli as an aggregate of package-local real-entry observations, and update TestResponseBudgetDefaultContract and existing package-local budget/knob tests (integration)
- A Build or Review stall beyond 600 seconds still ends provider/unavailable naming 10 minutes: retain/update existing fake-clock Build/Review stall and resume tests, required by TestShapeBudgetRoleContract (regression)
- Every run records the effective response budget exactly once even across multiple Respond calls: update existing Shape/Refine/init/Build log observations and require them in TestShapeBudgetRoleContract (integration)
- Removing the research knob leaves requests byte-identical and all other settings/retries unchanged: retain/update existing response-budget wire comparisons and settings checks in TestShapeBudgetRoleContract; assert research has no configurable response budget (regression)

Implement the named contracts as real behavioral tests, not source-text checks. Reuse cli/shape/response_budget_test.go and cli/build/response_budget_test.go fixtures. The streaming regression must advance simulated time while delivering valid incremental provider events through one logical Respond, then deliver a valid completion and allow Shape to finish; merely advancing time after completion or aborting the transport is not this reproducer. Assert observed elapsed simulated time is 800 seconds for that response and successful completion. No production abstraction solely for mocking is needed: the pinned client already exposes Now and transport seams.

The role contract must observe zero client ResponseBudget plus effective 30-minute transport budget for Shape, Refine and init, and explicit 10-minute budgets for Build and independent Review, using production settings. Exercise the real entry points, including normal fresh Build and resumed client setup. Require exact named test execution and PASS, rejecting absent, skipped or zero-run supporting tests; each failure must name the required test, command/package and outcome. Preserve useful existing regression coverage and replace obsolete all-roles-ten-minute expectations. All configured setup, acceptance and project checks must pass before landing.

## Feasibility
- Repository inspection confirms the pinned loop already provides zero=30 minutes, a client Now seam and explicit-budget diagnostics; required production edits are outside protected paths.
- The proposed named-test command route is available; the new regression contract does not exist yet. (probe 1: `cd cli && go test -count=1 -v -run '^TestShapeBudgetRoleContract$' .`, exit 0, 1.1 s; output reports no tests to run, not behavioral success)
