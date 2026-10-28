# Keep the source tag in decision feedback

Slug: k26b-source-tag
Model: not applicable — feedback text, card text and a stale-read fix; no state machine
Acceptance:
- .kogen/intents/k26b-source-tag/acceptance.feature
- features/steps/k26b_source_tag_steps.js
- features/steps/k26b_source_tag_driver.go

Research cells ended `intent/not_ready: decisions: a decision has no source` because K26's feedback said only to "mark the decision as an assumption", and shapers rewrote Decision lines to end with `(assumption: …)`, dropping the `(source: request)` / `(source: answer N)` tag that readiness requires (`sourceRe` in cli/project/intent.go). This change makes the feedback say exactly how to mark an assumption, keeps the K25c templates source-tagged, strips the source tag from the card's assumption list, and stops the card reading a stale audit result. The Intent format and the readiness rule are unchanged.

## Requirements
1. K26 feedback. The `Decision check: …` head line stays byte-identical (`Decision check: N stated decisions are not supported by the request; follow the request, or ask, or mark the decision as an assumption the user must confirm:`). The very next line is exactly: `Mark an assumption with (assumption: <what the user must confirm>) before the required trailing tag, e.g. - <decision> (assumption: <what the user must confirm>) (source: request); every Decision line keeps its trailing (source: request) or (source: answer N).` The per-problem `statement: … | request_quotes: … | why: …` lines follow it, unchanged. The decision-check instructions (`decisionInstructions`) and `docs/configuration.md` state the same rule: a marked assumption keeps its trailing `(source: …)`. Update the existing unit tests in `cli/shape/decision_test.go` that compare the feedback.
2. K25c templates. Every per-defect `- Decision: …` template ends with ` (source: request)` (the current code already does; keep it and keep the test).
3. Assumption rule and card. A Decision statement containing `(assumption:` anywhere is still never fed back. The card's `Assumptions to confirm` lines strip the trailing `(source: request)` or `(source: answer N)` tag: for the Decision line `- Zero counts as even. (assumption: the request is silent on zero) (source: request)` the card line is `  - Zero counts as even. (assumption: the request is silent on zero)`. Update `assumptionLines` and its test.
4. Stale card. The `Unresolved request conflicts` section must come from the uncovered defects of the Shape run that produced the current Intent, not from the last `request_audit` event in the ever-growing `.kogen/local/shaping/<slug>/events.ndjson`. After a successful Shape of a slug that was deleted and shaped again with `shape_audit` off (no audit event at all), or with every defect covered, the card shows no such section. The card after the run that left a defect uncovered still shows it, unchanged. The mechanism (for example a per-run record replaced at each publication) is the builder's choice; no change to the card format.

## Decisions
- The extra feedback line comes right after the unchanged head line, so existing readers of the first line and of the item lines keep working. (source: request)
- The assumption marker goes before the trailing source tag; the trailing tag is never replaced. (source: request)
- K25c templates end with ` (source: request)` because the decision follows from the request's statements. (source: request)
- The Intent format, `sourceRe` and readiness are not changed. (source: request)

## Source comparison
- addressed: feedback and instructions say how to mark an assumption, keeping the trailing tag (requirement 1; scenario 1 follows the feedback literally by filling the example line it gives, and passes readiness).
- addressed: K25c templates end with `(source: request)` (requirement 2; already true in the code, scenario 2 pastes the template and passes readiness as regression).
- addressed: `(assumption:` recognised anywhere in the line, card strips the trailing source tag (requirement 3; scenario 1 checks the exact card line).
- addressed: stale card section comes from the current run (requirement 4; scenarios 3 and 4, audit off and everything covered).
- addressed: no change to Intent format or readiness (requirements; no test change there).
- omitted: no real provider calls and no process control in tests, per host safety; the driver uses a scripted local provider.

## Tests
- feedback has the exact assumption instruction line after the unchanged head and keeps the source tag when followed: update `cli/shape/decision_test.go` (unit); scenario 1 (scenario)
- decision-check instructions and docs state the rule: update `decisionInstructions` and `docs/configuration.md`; covered by a check of the instructions text in `cli/shape/decision_test.go` (unit)
- card assumption lines drop the trailing source tag: update the assumption-lines test in `cli/shape/decision_test.go` (unit); scenario 1 (scenario)
- K25c templates end with `(source: request)` and a pasted template passes readiness: existing `cli/shape/audit_test.go` (existing); scenario 2 (scenario)
- stale `Unresolved request conflicts` after reshape with audit off or all covered: update `TestApproveCardUnresolvedConflicts` in `cli/shape/approve_test.go` to the per-run source (integration); scenarios 3 and 4 (scenario)

## Feasibility
- The driver compiles as a go -overlay test on the unchanged tree. Observed on it: the audit-template and covered-reshape modes publish and reach the card (exit 5); the stale mode shows the section again after a reshape with audit off (legitimate red); the assume mode fails because the unchanged feedback has no example line, the literal-following shaper then drops the source tag and Shape stops on a provider error with no script left (legitimate red). (probe: three go test runs ok, 13.7 s)
- evidence: {"id":"k26b-observer","kind":"observer","inputs":["features/steps/k26b_source_tag_driver.go"],"observers":["features/steps/k26b_source_tag_steps.js"],"checks":[{"name":"good","command":"\"$KOGEN_NODE\" features/steps/k26b_source_tag_steps.js --control good","exit":0,"output":"k26b observer good\n"},{"name":"bad","command":"\"$KOGEN_NODE\" features/steps/k26b_source_tag_steps.js --control bad","exit":1,"output":"k26b observer rejected bad fixtures\n"}]}
