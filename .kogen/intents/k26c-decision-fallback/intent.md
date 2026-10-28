# Mark unsupported decisions on the last attempt

Slug: k26c-decision-fallback
Model: not applicable — a last-attempt branch of one gate, one event and a retention rule; no state machine
Acceptance:
- .kogen/intents/k26c-decision-fallback/acceptance.feature
- features/steps/k26c_fallback_steps.js
- features/steps/k26c_fallback_driver.go

K25c lets the request-audit gate publish on the last attempt, but the K26 decision check still refuses: a Decision marked `unsupported` that the shaper never marks as an assumption ends Shape as `intent/not_ready`. Also, the shaping events do not record what a refused submission was told, and an external shaper whose first all-files submission is refused by the audit gate loses those files, so its correction (naming only changed files) ends as `acceptance.feature does not exist`. This change fixes those three things in `cli/shape/shape.go` and `cli/shape/decision.go`.

## Rules
1. Last attempt. The last attempt is the existing one (`sh.priorInvalid >= 2`, native and external). On it, when the decision check flags problems and every flagged item has verdict `unsupported` (none `contradicts`) and each flagged statement is a line of the `## Decisions` section that ends with a `(source: request)` or `(source: answer N)` tag, Kogen itself rewrites each such line by inserting ` (assumption: <why>)` before that trailing tag, where `<why>` is the check's `why` with whitespace runs collapsed to single spaces and trimmed (one line). It writes the result to intent.md and to the accumulated proposals, records one event `decision_assumptions_marked` with `statements` (the list of the check's statements that were marked, as the check gave them), does not call the decision check again, and continues with the step self-check, readiness and publication. The approval card then lists those lines under the existing `Assumptions to confirm` (the existing card code, unchanged). If any flagged item is `contradicts`, or a flagged statement is not a marker-eligible Decisions line, nothing is marked and the submission is refused as today. Earlier attempts are unchanged: feedback as today, nothing marked.
2. Refusal record. Each refused submission records one `submission_refused` event in the shaping events (`.kogen/local/shaping/<slug>/events.ndjson`) with `attempt` (1-based count of submissions in this Shape run), `gate` and `problems` (the problem lines given back to the shaper, at most 20 lines, each cut to at most 300 characters; no file contents or request text beyond those lines). Gate names: `validation` (envelope or file validation), `audit` (request-audit gate), `publication` (inspection/documentation), `intent` (Intent lint/parse of the accumulated package), `retained` (abandoned declared artifacts), `decision_check`, `step_selfcheck`, `readiness`. For `decision_check` the problems are the lines given back without the headline line. Accepted red observations (acknowledgment) are not refusals. Native and `executor: claude-code` paths both.
3. Correction keeps earlier files. Cause: a files submission that is well formed but refused by the audit gate before it was merged into the accumulated proposals retained nothing, while the feedback told the shaper only to correct; an external shaper that then resubmitted only the changed files (for example `intent.md`) had no `acceptance.feature`. Now the well-formed files of a submission refused by the audit gate are merged into the accumulated proposals (as for refusals after merging, such as the decision check), exactly as the native path treats later refusals, and the Cumulative proposal manifest in the feedback lists them. The audit gate's feedback text is unchanged. Refusals by validation of the envelope/files and by publication (uninspected, documentation) still retain nothing, with their text unchanged.

Unchanged: no new command, flag or output line (the card's existing `Assumptions to confirm` section and the new events only), no attempt budget, timeout or limit raised, a contradicting Decision is never published.

## Decisions
- Only `unsupported` items are auto-marked, and only when their statement is a tagged line of `## Decisions`; anything else keeps today's refusal. (source: request)
- The decision check is not re-run after marking; the package/readiness checks run on the result. (source: request)
- The cause of the missing acceptance.feature is the audit gate dropping a refused submission's files; correcting it is done by retaining them, not by changing the external executor. (source: request)
- Gate names and the `statements`/`attempt`/`gate`/`problems` fields are fixed by this Intent because the request leaves their spelling open. (source: request)

## Source comparison
- addressed: decision-check last-attempt fallback with `(assumption: <why>)` before the source tag, card listing, event `decision_assumptions_marked` (rule 1; scenario 1). The `contradicts` item stays refused (scenario 2).
- addressed: `submission_refused` event per refused submission with attempt, gate, problems bounded to 20 lines x 300 characters, native and external (rule 2; scenarios 1-4).
- addressed: wrapcol cause found by reading the code (the evidence files were not available): the audit gate refusal drops all files of the submission; fixed by retaining them (rule 3; scenario 4 with a fake external shaper: audit refusal of all files, then an intent.md-only correction ends published with acceptance.feature).
- clarified: a flagged statement that is not a tagged Decisions line is not marked (scenario 3 exercises refusal with such statements).
- addressed: must stay: no new command/flag/output line, no raised limit, contradicting Decision never published, existing tests pass (existing).

## Tests
- last-attempt marking of unsupported Decision lines, no marking for contradicts or ineligible statements, no marking before the last attempt: add cases in `cli/shape/decision_test.go` (unit); scenarios 1-3 (scenario)
- `submission_refused` event for each gate with bounds: add cases in `cli/shape/shape_test.go` (integration); scenarios 1-3 (scenario)
- audit-gate refusal retains the submission's files, native and external: add a case with the fake external shaper in `cli/shape/audit_test.go` (regression); scenario 4 (scenario)
- card lists marked lines under Assumptions to confirm: scenario 1 (scenario)
- earlier behavior of K25c, K26 and K26b: the existing tests and scenarios (existing)

## Feasibility
- evidence: {"id":"k26c-observer","kind":"observer","inputs":["features/steps/k26c_fallback_driver.go"],"observers":["features/steps/k26c_fallback_steps.js"],"checks":[{"name":"good","command":"\"$KOGEN_NODE\" features/steps/k26c_fallback_steps.js --control good","exit":0,"output":"k26c observer good\n"},{"name":"bad","command":"\"$KOGEN_NODE\" features/steps/k26c_fallback_steps.js --control bad","exit":1,"output":"k26c observer rejected bad fixtures\n"}]}
