# Stop the audit gate refusing on the last attempt

Slug: k25c-gate-no-refusal
Model: not applicable — a feedback text and a last-attempt branch of one gate; no state machine
Acceptance:
- .kogen/intents/k25c-gate-no-refusal/acceptance.feature
- features/steps/k25c_gate_steps.js
- features/steps/k25c_gate_driver.go

With `shape_audit` on, the K25 coverage gate (`auditGate` and its call in `submit`, `cli/shape/audit.go` and `cli/shape/shape.go`) rejects a files or questions submission while an audit defect is neither decided nor asked. Three invalid submissions in a row end Shape as `shape/invalid_output`, so a shaper that cannot find the way to satisfy the gate gets no result at all, although the audit caught the defect. This change makes the feedback actionable and gives the last attempt a safe outcome.

## Rule changes
1. Feedback. `auditGate(sub submission) []string` keeps its signature and keeps returning the strict feedback lines whatever the attempt. The headline (`Request audit: N defects are not decided or asked; decide each with its exposing input or ask with both quotes:`) and each defect line (`quote_a: <quote_a> | quote_b: <quote_b> | exposing_input: <exposing_input>`) are unchanged. After each defect line come these ready lines, built from the audit data (the character after `because` is U+2026 `…`; every line is literal text to paste):
   - `conflict` and `precedence`: one line per non-empty result among `result_a`, `result_b` (in that order): `- Decision: for <exposing_input> the result is <result> (because …) (source: request)`. When both results are empty the single line uses `<result>` as the literal text. One line per result, because a Decision naming both results does not cover the defect (K25b rule); the shaper keeps the line for the result it decides.
   - `undefined`: `- Decision: <quote_b>: <definition> (because …) (source: request)` with `<definition>` as the literal text.
   - every defect, last: `- Question: "<quote_a>" versus "<quote_b>": which applies?` (it quotes both statements, so it covers the defect under the K25 question rule).
   Each template line, pasted unchanged into `## Decisions` (or as a question), covers its defect under the unchanged K25/K25b coverage rules, and carries the `(source: request)` suffix that Intent lint requires.
2. Last attempt. The shaper's last allowed attempt is the one that, if invalid, would end Shape under the existing three-in-a-row rule: both the native and the external conversation already count invalid submissions, so the attempt is the one made with two invalid submissions before it. No new limit. On that attempt a questions or files submission that is not covered by the K25 rules is NOT refused for coverage: for files it continues through the K26 decision check (when on), the K20 step self-check and readiness exactly as a covered one; questions are accepted as before. Earlier attempts keep the strict gate: the feedback text above, nothing written or published. Blocked reports stay ungated.
3. Record. When a files submission published on the last attempt left defects uncovered, the run records them in a `request_audit` event as `uncovered` (the list of those defect objects exactly as in `defects`). The event is recorded when the candidate is ready (a second `request_audit` event after the first is allowed); the card reads the LAST `request_audit` event of the Intent's shaping evidence (`.kogen/local/shaping/<slug>/events.ndjson`), so a later run with no uncovered defects shows nothing. Events without `uncovered` (or with an empty list) are unchanged.
4. Approval card. `kogen intent approve <slug>` (the card, exit 5) prints, when the last `request_audit` event has a non-empty `uncovered`, a section headed by the exact line `Unresolved request conflicts`, between the optional `Assumptions to confirm` and the `Files` line, with one line per uncovered defect: `  - quote_a: <quote_a> | quote_b: <quote_b> | exposing_input: <exposing_input>`. With no uncovered defects (including audit off) the card is byte-for-byte unchanged.

Unchanged: `shape_audit` off; no new round limit, timeout or retry; K25b coverage rules (`uncoveredDefects`); the audit call itself.

## Decisions
- The strict gate keeps refusing on attempts before the last, with the template in the feedback, so a shaper that follows it covers the defect. (source: request)
- The last attempt is defined by the existing invalid counter, not by a new counter or limit. (source: request)
- The template carries a `(source: request)` suffix after `(because …)` because Intent lint rejects a Decision without a source, and the request requires pasted templates to cover; one line per result because a line with both results never covers. (source: request)
- The uncovered defects are shown on the card from the shaping evidence event, not from a new file. (source: request)
- Questions on the last attempt are accepted as before; only the refusal for coverage is lifted. (source: request)

## Source comparison
- addressed: feedback template for conflict/precedence/undefined plus question alternative, headline kept (rule 1; scenarios 1-3).
- clarified: the conflict template `<result_a or result_b>` is rendered as one line per result and gains a `(source: request)` suffix so that pasting it covers the defect and passes lint (rule 1).
- addressed: last attempt continues to K26/K20/readiness, uncovered defects recorded in `request_audit` as `uncovered` and shown on the card under `Unresolved request conflicts` with quotes and exposing inputs (rules 2-4; scenario 1).
- addressed: earlier attempts strict (scenario 1 observes feedback on attempts 1 and 2 and no self-check before the last).
- addressed: a shaper pasting the template covers on the next attempt, no uncovered recorded, card has no section (scenario 2).
- addressed: must stay — audit off, round rules, K25b coverage rules, no new limit; the existing K25 and K25b scenarios and tests stay green (existing). The existing unit test `TestAuditGateFeedback` compares exact feedback lines and must be updated to the new lines.
- addressed: all configured checks pass is the Build's normal gate.

## Tests
- feedback template lines per defect kind and the question alternative: update `TestAuditGateFeedback` and add table cases in `cli/shape/audit_test.go` for conflict, precedence, undefined and empty results, and that each pasted line is covered by `uncoveredDefects` (unit)
- last attempt publishes uncovered defects (native and external), earlier attempts refuse, `uncovered` recorded, no `shape/invalid_output`: add cases in `cli/shape/audit_test.go` (integration); scenario 1 (scenario)
- card section `Unresolved request conflicts` with quotes and exposing input, absent when none uncovered or audit off: add a case in `cli/shape/approve_test.go` (integration); scenarios 1-2 (scenario)
- pasting the template covers the defect on the next attempt: scenario 2 (scenario)
- undefined template: scenario 3 (scenario)
- audit off and existing K25/K25b behavior: the existing K25 and K25b scenarios and tests (existing)

## Feasibility
- evidence: {"id":"k25c-observer","kind":"observer","inputs":["features/steps/k25c_gate_driver.go"],"observers":["features/steps/k25c_gate_steps.js"],"checks":[{"name":"good","command":"\"$KOGEN_NODE\" features/steps/k25c_gate_steps.js --control good","exit":0,"output":"k25c observer good\n"},{"name":"bad","command":"\"$KOGEN_NODE\" features/steps/k25c_gate_steps.js --control bad","exit":1,"output":"k25c observer rejected bad fixtures\n"}]}
