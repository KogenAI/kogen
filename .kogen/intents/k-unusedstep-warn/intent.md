# Warn about unused step definitions

Slug: k-unusedstep-warn
Model: not applicable — this changes diagnostic severity, not a state machine
Acceptance:
- .kogen/intents/k-unusedstep-warn/acceptance.feature
- features/steps/k_namedfeedback_steps.js

Make K-UNUSEDSTEP-WARN apply to both Shape's step self-check and readiness: an unused step definition is a warning, never by itself a publication refusal. Record warnings in the shape result and run log, naming both the definition pattern and its file. Include reused step files' otherwise-unused definitions in this policy. Replace the present fatal treatment, not the other validation rules. No new CLI command, flag or project.yaml key. Do not change cli/third_party/kogen-loop/** or cli/loop-pin.json. All configured checks must pass.

## Decisions
- Dead step text warns; undefined steps, ambiguous steps, load errors and exit-code-wrapper violations still refuse with today's feedback and output format (source: request)
- Warnings remain observable in the result and run log even when an Intent successfully publishes (source: request)

## Source comparison
- Addressed: request K-UNUSEDSTEP-WARN's self-check and readiness severity change, result/log warning with definition and file, publication and reused-file reproduction are specified above and in the acceptance matrix.
- Addressed: request's four preserved refusal categories and unchanged feedback are required for both paths by the negative regression matrix; tests must compare existing failure feedback, not merely nonzero exit.
- Addressed: no commands, flags or keys, protected loop paths, configured checks and shared-host safety remain binding. Tests use disposable local repositories and only their own processes; no process-name termination or synthetic CPU load.
- Historical motivation (outputs/_internal/UNTESTED-STEP0-3-6.md, 29 Oct 2026; 11 of 55 failures; M9 documentation-lookup-evidence; delivery issue filed 29 Oct) is context, not a requirement to recreate those runs. Their unused-only and reused-file counterexamples are covered by the regression cases. No requested behavior is intentionally omitted or superseded.

## Tests
- Unused-only Shape candidate publishes with named file/pattern warnings in result and run log: add TestUnusedStepWarnShape through the real Shape entry point and scripted local provider (regression)
- Reused step files with extra definitions do not block publication: add TestUnusedStepWarnReused with one used and one unused definition in the reused file (regression)
- Undefined, ambiguous, load-error and wrapper self-check failures retain current feedback: add TestUnusedStepWarnShapeRefusals matrix (regression)
- Readiness accepts unused-only candidates with retained warnings and refuses the four other defects: add TestUnusedStepWarnReadiness and TestUnusedStepWarnReadinessRefusals using real readiness and local Cucumber fixtures (integration)
- Existing checks, failure formatting and public configuration remain unchanged: run configured checks and relevant self-check/readiness tests, updating only expectations superseded by warning severity (existing)

The acceptance launcher is an independent named-test harness; implementation regression tests belong in cli/shape and cli/verify, not in Acceptance. Each named test must exercise the described real entry point, not assert source text or manufacture a warning. Shape tests inspect the published package, returned/retained result and actual run log after a single unused-only submission, without a corrective second submission. Negative matrices assert all four cases separately, including exact existing feedback. Readiness tests run without relying on Shape prefiltering; exercise actual local step loading/matching and exit-wrapper validation, preserving readiness's existing legitimate missing-feature-red policy. An unused warning must not suppress another defect. Update existing unused-is-fatal regression expectations where needed; preserve useful other coverage.

## Feasibility
- none
