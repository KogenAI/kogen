# Audit requests for conflicts and gate coverage

Slug: k25-request-audit
Model: not applicable — one opt-in pre-conversation call and one deterministic publication check; no state machine
Acceptance:
- .kogen/intents/k25-request-audit/acceptance.feature
- features/steps/k25_request_audit_steps.js
- features/steps/k25_request_audit_driver.go

Shape catches few request defects (two statements giving different results for one input, missing precedence, undefined names) and never asks a question naming both conflicting statements. This change adds an **opt-in** mechanism: a request audit before the shaper's conversation, and a mechanical coverage gate before publication. With the config key absent Shape is unchanged: same provider requests (no audit request, no audit tool, no audit text in any request), same event stream (no `request_audit` event), same usage line, no new timeout, retry or round limit.

## Config
`.kogen/project.yaml` accepts `shape_audit: {enabled: true}` (`Config.ShapeAudit.Enabled`, default false). Validation matches `shape_workers`: `shape_audit` must be a mapping (`shape_audit must be a mapping`), `enabled` a YAML Boolean (`shape_audit.enabled must be a Boolean`), any other key is refused as `line N: unknown key <key>`. Document the key in `docs/configuration.md`.

## The audit call (enabled only; native and external Shape)
Once per `kogen intent shape` invocation that reaches the model conversation (after pending questions are answered, before the first shaper request), Kogen makes one fresh, read-only call on the configured shape route:
- Native: one provider request with the shape role, no other conversation state, whose **only** tool is `submit_audit` (its parameters are the strict JSON schema below). Its input is the request text (`state.Request`) and nothing else (no repository context, README, navigation block or Q&A), plus instructions containing the Intent template's definition of the three defect kinds. The model answers by calling `submit_audit`. No new timeout, retry or round limit: provider failures follow the existing Shape provider-failure path; an answer that is not a valid `submit_audit` payload stops Shape with `shape/audit_invalid` (exit 1), publishing nothing.
- External (`executor: claude-code`): one fresh read-only session with the same input and the same schema as its structured result; its round counts in the usage line's round count.
- `submit_audit` payload: `examples`: list of `{quote}`; `rules`: list of `{quote}`; `cells`: list of `{example: <index into examples>, rule: <index into rules>, result: "agrees"|"conflicts"|"silent"}`; `defects`: list of `{kind: "conflict"|"precedence"|"undefined", quote_a, quote_b, exposing_input, result_a, result_b}`. For `undefined`, `quote_b` is the missing name. Each quote is text copied exactly from the request.
- Exactly one event `{"event":"request_audit","examples":<count>,"rules":<count>,"cells":<count>,"defects":[<the defect objects as returned>]}` is recorded in the shaping `events.ndjson`, before the shaper's first request. The audit call's tokens are counted in the usage total printed by Shape (`shape <model>/<effort> input=… cached=… output=… reasoning=…`), like any other shape call.
- The shaper receives the audit result as data in its first request (a labelled block containing every defect's `quote_a`, `quote_b` and `exposing_input`); it is lower-authority evidence, not scope.

## Coverage gate
When the audit has defects, every submission of questions or files is checked mechanically (no model judgement) before anything is written or checked, hence before the K20 step self-check and readiness, which are unchanged and run after the gate. A defect is covered when either:
- a line inside the `## Decisions` section of the candidate `intent.md` (the submitted one, else the accumulated proposal) contains the defect's `exposing_input` verbatim and does not contain both `result_a` and `result_b` (it states one result); or
- some question of the submitted `questions` contains both `quote_a` and `quote_b` verbatim (for `undefined`: `quote_a` and the missing name).
If any defect is uncovered, nothing is written or published and the submission's tool result (external: the next round's feedback) is exactly:
`Request audit: N defects are not decided or asked; decide each with its exposing input or ask with both quotes:` where N is the number of uncovered defects, followed by one line per uncovered defect, each containing its `quote_a`, `quote_b` and `exposing_input`. This is an invalid submission under the existing rules (three in a row end Shape as today); no new limit. Blocked reports are not gated. With no defects the gate does nothing.

## Decisions
- The audit and gate exist only with `shape_audit.enabled: true`; the default is off and Shape is then unchanged. (source: request)
- The audit sees only the request text and the template's defect definitions, is read-only, and is one call without added timeout, retry or round limit. (source: request)
- Coverage is judged by exact substring rules above, never by a model. (source: request)
- Native audit output is delivered through a forced `submit_audit` tool call because the provider layer has no other structured-output channel; a malformed answer stops Shape with `shape/audit_invalid`. (source: request)
- The `request_audit` event field names (`examples`, `rules`, `cells` as counts; `defects` as objects) and the feedback headline are fixed here so behavior is observable. (source: request)

## Source comparison
- addressed: request audit pass native and external, one fresh read-only call, strict schema with examples, rules, cells, defects; recorded as one `request_audit` event; given to the shaper as data; tokens counted in usage (scenarios 1-2 observe native; external has the integration test below).
- addressed: coverage gate — Decision line with `exposing_input` verbatim stating one result, or a question with both quotes; one-list feedback with the exact headline in the same conversation; nothing published until covered; no new round limit (scenarios 2-5).
- addressed: opt-in `shape_audit: {enabled: true}`, default off, unknown keys refused (scenario 7, config unit test); with it off request bytes and events carry no audit trace (scenario 6).
- addressed: must stay — K20 self-check unchanged and after the gate (scenario 2 asserts exactly one `step_selfcheck`, after the audit event, and the feedback precedes it).
- clarified: "states one result" is made mechanical as: the line does not contain both `result_a` and `result_b` (scenario 3).
- omitted: "All configured checks pass" is the Build's normal gate; benchmarking on the 16 flawed-request cases is research, outside this Intent. External audit is not driven by a scripted acceptance scenario; it is covered by an integration test in `cli/shape`.
- literal "request bytes identical to today" is checked as absence of any audit request, tool, text or event plus an unchanged usage line, not as a byte diff against an old binary.

## Tests
- config key `shape_audit` parses, defaults off, refuses unknown keys and non-Boolean `enabled`: add to `cli/project/config_test.go` (unit)
- coverage rule (Decision line with exposing input and one result; question with both quotes or quote and missing name; uncovered feedback text): add table tests in `cli/shape` (unit)
- enabled native Shape: audit call is first, sees only the request, event recorded with counts and defects, usage includes it, uncovered first submission fed back and corrected second published: scenarios 1-2 (scenario)
- a Decision line stating both results does not cover: scenario 3 (scenario)
- a question with both quotes covers; one quote does not: scenarios 4-5 (scenario)
- audit off: no audit request, tool, text, event; usage unchanged: scenario 6 (scenario)
- unknown key under `shape_audit` refused before any provider request: scenario 7 (scenario)
- external Shape runs the audit as one fresh read-only session and applies the same gate: add an integration test in `cli/shape` using the scripted external session (integration)
- clean audit (no defects) publishes in one shaper round with the event and no feedback: scenario 1 (scenario)

## Feasibility
- The driver compiles against the unchanged tree as a go -overlay test; with the key absent (mode off) it passes on the unchanged code, and with the key present the unchanged code refuses `unknown key shape_audit`, so the enabled scenarios are legitimate missing-feature red. (probe 2: off exit 0 and published; clean exit 3 with `line 5: unknown key shape_audit`, 11 s)
- The observer's good controls accept and bad controls reject. (probe 1: good exit 0, bad exit 1, 0.1 s)
- evidence: {"id":"k25-observer","kind":"observer","inputs":["features/steps/k25_request_audit_driver.go"],"observers":["features/steps/k25_request_audit_steps.js"],"checks":[{"name":"good","command":"\"$KOGEN_NODE\" features/steps/k25_request_audit_steps.js --control good","exit":0,"output":"k25 observer good\n"},{"name":"bad","command":"\"$KOGEN_NODE\" features/steps/k25_request_audit_steps.js --control bad","exit":1,"output":"k25 observer rejected bad fixtures\n"}]}
