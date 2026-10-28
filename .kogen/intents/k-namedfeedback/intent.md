# Name missing required tests in failure feedback

Slug: k-namedfeedback
Model: not applicable — enrich existing failure diagnostics without changing verification state or transitions
Acceptance:
- .kogen/intents/k-namedfeedback/acceptance.feature
- features/steps/k_namedfeedback_steps.js

Enrich builder-facing verification failures for acceptance steps requiring named tests. For every failed step whose required test did not run (absent run, zero runs, skipped test, or “no tests to run”), report exact required test ids, the command or package in which acceptance ran them, and the step definition file and line. Derive identity from the step's arguments and execution evidence (including -run selectors and go test -json rows), not solely assertion wording. Preserve ordinary assertion feedback exactly. This replaces opaque “required test must run exactly once / 0 !== 1” diagnostics, not verdicts.

## Decisions
- Keep verdicts, CLI, project.yaml, limits, timeouts and retries unchanged; passing builds send byte-identical requests. Add no diagnostic text to passing requests. (source: request)
- New-intent shaping guidance requires named-test helpers to include the required test name in assertion messages. Put guidance in Shape-specific instructions, not shared builder instructions that would alter passing requests. (source: request)
- Use deterministic local fake builders, temporary repositories and real acceptance execution; no paid model calls. Never stop processes by name or pattern, only pids started by the test; no synthetic CPU load. (source: request)

## Source comparison
- addressed: request What 1 and all four absence cases by Tests and the named-test regression scenario; exact ids, command/package and definition location must survive into the builder's next feedback, even with generic assertion text and several required ids/steps.
- addressed: What 2 and Must stay by the compatibility regression scenario and existing feedback golden tests; generic failures and passing requests remain byte-identical, verdicts and operational budgets unchanged.
- addressed: What 3 by Shape-specific guidance and its regression test; no CLI/project.yaml changes.
- addressed: fault acceptance by TestNamedFeedbackBuilderRepair: wrong name first, feedback-driven correction second, real verification passes; all configured checks remain mandatory.
- omitted from automated delivery: request Control run is explicitly post-landing research: K-REVIEWRETRY on Terra high plus a Sonnet native build of the same Intent. Do not execute those paid control runs during implementation or claim their results. Historical evidence outputs/_internal/NAMED-TESTS-BUILDERS.md (28 Oct 2026), f8585123's 2 differently named tests and 0 of 7 required tests/no_progress, Terra 4/8 versus Sonnet 0/17, and K-PIN-KNOBS convergence after 5 red passes motivate but do not establish this change's results.
- conflicting/superseded: none; no change to verification authority or acceptance success criteria.

## Tests
- Missing named-test diagnostics: add TestNamedFeedbackMissingTests in cli/verify, exercising real acceptance helpers and report accounting for absent, zero, skip and no-tests outcomes, generic assertion wording, multiple ids and steps, and checking exact identity, command/package and definition file/line in Pass.Feedback (regression)
- Feedback reaches the repair owner: add TestNamedFeedbackBuilderRepair in cli/build using the existing local fake builder infrastructure; first writes a wrongly named test, next request must contain expected name/package/location, correction selected from that feedback passes actual acceptance and finishes successfully (integration)
- Unchanged behavior: add TestNamedFeedbackCompatibility in cli/build comparing ordinary assertion feedback and passing rendered builder requests byte-for-byte to their pre-change forms, and checking unchanged verdicts; retain existing cli/verify feedback golden coverage (regression)
- Named-test authoring guidance: add TestNamedFeedbackShapeGuidance in cli/shape checking actual rendered shaping instructions require test names in assertion messages (regression)
- Configured checks: run all configured checks without weakening or editing project.yaml, raising budgets or changing CLI (existing)

Implementation tests listed above are editable production-side tests, not protected acceptance artifacts. They must exercise observable real boundaries, not assert helper implementation structure. The protected acceptance runs them by exact name and rejects absent or skipped tests. Retain the underlying meaningful assertions; a placeholder passing test is not delivery.

## Feasibility
- none
