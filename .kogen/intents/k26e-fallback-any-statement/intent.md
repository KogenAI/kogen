# Mark flagged prose statements on the last attempt

Slug: k26e-fallback-any-statement
Model: not applicable — a one-shot rewrite rule with no evolving state
Acceptance:
- .kogen/intents/k26e-fallback-any-statement/acceptance.feature
- features/steps/k26e_fallback_steps.js
- features/steps/k26e_fallback_driver.go

K26c's last-attempt fallback (`markAssumptions` in `cli/shape/decision.go`, called from `checkSubmission` in `cli/shape/shape.go` when `sh.priorInvalid >= 2`) marks only when every flagged decision-check item is a tagged `## Decisions` line. This Intent extends it to flagged statements found elsewhere in intent.md (for example explicit-result fragments in the prose).

On the last attempt, when every flagged item (verdict not `follows`, statement not already containing `(assumption:`) is `unsupported` and none is `contradicts`:

1. A flagged item that is a tagged Decisions line (as today) is marked in place: ` (assumption: <why>)` inserted before its trailing source tag.
2. A flagged item whose statement is found in intent.md (whitespace-normalised, as `containsNormalized`) but is not a tagged Decisions line gets one new line appended at the end of the `## Decisions` section (after its last non-blank line): `- <statement, whitespace-normalised, with a leading "- " and trailing whitespace removed> (assumption: <why>) (source: request)`. `<why>` is the check's why with whitespace runs collapsed and trimmed (one line). The prose is left unchanged. The same statement is added once.
3. If any flagged statement is found nowhere in intent.md, nothing is marked and the submission is refused as today. A `contradicts` item refuses as today.
4. One `decision_assumptions_marked` event lists all marked statements: `statements` (as the check gave them, in item order, as today) plus a new parallel list `placement` of the strings `in_place` or `added`.

The approval card lists all of them under the existing `Assumptions to confirm` (existing card code). Earlier attempts are unchanged. The existing unit test of `markAssumptions` may be updated if its signature changes. No attempt budget, timeout or limit is raised, no new command, flag or output beyond the event field is added, the decision check is not re-run after marking, and readiness and publication checks run on the result as today.

## Decisions
- Last-attempt marking of prose fragments appends new lines to `## Decisions` and leaves the prose unchanged. (source: request)
- The event field naming the placement is `placement`, parallel to `statements`, valued `in_place` or `added`. (source: request)

## Source comparison
- addressed: tagged lines marked in place, prose fragments appended with marker and `(source: request)` (scenario 1); statement missing from intent.md refuses with nothing changed (scenario 2); `contradicts` refuses (scenario 3); one event naming all with in_place/added (scenario 1); card lists all four (scenario 1).
- addressed: earlier attempts unchanged, no budget/limit/command/flag change, no re-run of the decision check (scenario 1 counts three checks, two refused attempts).
- addressed: "All configured checks pass" and existing tests pass through normal verification.
- omitted: the exact field name for in_place/added was unspecified; `placement` was chosen.

## Tests
- Last attempt with two tagged lines and two prose fragments all unsupported publishes, marks in place, appends two lines, lists four assumptions, event names all four: scenario k26e "mixed" (scenario)
- A flagged statement not in intent.md refuses with nothing changed: scenario k26e "missing" (scenario)
- A contradicts item refuses: scenario k26e "contradicts" (scenario)
- K26c behaviour (one tagged line marked, earlier attempts unchanged): existing k26c scenarios and `decision_test.go` (existing)

## Feasibility
- evidence: {"id":"k26e-observer","kind":"observer","inputs":["features/steps/k26e_fallback_driver.go"],"observers":["features/steps/k26e_fallback_steps.js"],"checks":[{"name":"good","command":"\"$KOGEN_NODE\" features/steps/k26e_fallback_steps.js --control good","exit":0,"output":"k26e observer good\n"},{"name":"bad","command":"\"$KOGEN_NODE\" features/steps/k26e_fallback_steps.js --control bad","exit":1,"output":"k26e observer rejected bad fixtures\n"}]}
