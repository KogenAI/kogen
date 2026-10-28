# Check stated Decisions against the request

Slug: k26-decision-check
Model: not applicable — one opt-in read-only call per candidate and a deterministic substring check; no state machine
Acceptance:
- .kogen/intents/k26-decision-check/acceptance.feature
- features/steps/k26_decision_check_steps.js
- features/steps/k26_decision_check_driver.go

Shape can state a Decision that contradicts, or is not found in, the request. This change adds an **opt-in** check of Shape's output: after each complete candidate, a fresh read-only call compares the candidate `intent.md` with the request. With the config key absent Shape is unchanged: same provider requests (no check request, tool or text), same events (no `decision_check` event), same usage line, same approval card, no new timeout, retry or round limit. K25 (request audit and coverage gate) and K20 (step self-check) are unchanged.

## Config
`.kogen/project.yaml` accepts `shape_decision_check: {enabled: true}` (`Config.ShapeDecisionCheck.Enabled`, default false). Validation matches `shape_audit`: `shape_decision_check must be a mapping`, `shape_decision_check.enabled must be a Boolean`, any other key is refused as `line N: unknown key <key>`. Document the key in `docs/configuration.md`.

## The check call (enabled only; native and external Shape)
When is it made: for every submission of files whose accumulated candidate `intent.md` passes the existing submission validation, the K25 coverage gate (when on) and the package check, and **before** the K20 step self-check and readiness. Question and blocked submissions are not checked. Each candidate gets one call, including a resubmission of identical files.
- Native: one fresh provider request with the shape role and no other conversation state, whose **only** tool is `submit_decision_check` (strict JSON schema). Its input is the request text (`state.Request`) and the candidate `intent.md` text, plus instructions, and nothing else (no README, navigation block, Q&A, repository context, audit text). Read-only: no other tool. The model answers by calling `submit_decision_check`. No new timeout, retry or round limit; provider failures follow the existing Shape provider-failure path; an answer that is not a valid payload stops Shape with `shape/decision_check_invalid` (exit 1) publishing nothing.
- External (`executor: claude-code`): one fresh read-only session with the same input and schema as its structured result; its round counts in the usage line's round count.
- Payload `{"items": [{"statement", "request_quotes": [string...], "verdict": "follows"|"contradicts"|"unsupported", "why"}]}`. The instructions ask for one item for every line of the candidate's `## Decisions` section and for every explicit result the intent states for a concrete input in its prose or examples; `statement` is text copied exactly from `intent.md` (for a Decisions line, the whole line) and each quote is text copied exactly from the request.

## Mechanical check (no model judgement)
- An item whose `statement` is not a substring of the candidate `intent.md`, or one of whose `request_quotes` is not a substring of the request, counts as `unsupported` whatever verdict was returned.
- An item whose statement contains `(assumption:` is an assumption: it is **not** fed back, whatever its verdict.
- Every other item with verdict `contradicts` or `unsupported` (after the rule above) is a problem. With any problem, nothing is published for this submission's turn and the submission's tool result (external: the next round's feedback) is exactly one list: the headline `Decision check: N stated decisions are not supported by the request; follow the request, or ask, or mark the decision as an assumption the user must confirm:` (N = number of problems) followed by one line per problem in the form `statement: <statement> | request_quotes: "<quote1>", "<quote2>" | why: <why>` (no quotes listed when there are none). It is an invalid submission under the existing rules (three in a row end Shape as today); no new limit. The proposals stay accumulated as for other feedback, and the next candidate is checked again.
- No problems: the candidate goes on to the K20 step self-check and readiness as today.

## Event and usage
Each call records one event `{"event":"decision_check","follows":<n>,"contradicts":<n>,"unsupported":<n>,"items":[<each item as returned, with its verdict replaced by unsupported where the mechanical rule applied>]}` in the shaping `events.ndjson`; the counts are counts of those final verdicts (assumption items included). Every call's tokens (native) or rounds (external) are counted in the usage line Shape prints, like any other shape call.

## Approval card
With `shape_decision_check.enabled: true`, `kogen intent approve <slug>` (card form, no hash) prints a block headed `Assumptions to confirm` with one line `  - <decision text without its leading "- ">` for each line of the `## Decisions` section of the Intent that contains `(assumption:`, after the source comparison and before `Files`. No such lines, or the key absent: the card is unchanged.

## Decisions
- The check exists only with `shape_decision_check.enabled: true`; the default is off and Shape and the card are then unchanged. (source: request)
- The call sees only the request text and the candidate `intent.md`, is read-only, and is one call per complete candidate without added timeout, retry or round limit. (source: request)
- Support is judged by exact substring rules above, never by a model; an `(assumption: …)` Decision is not fed back but listed on the approval card. (source: request)
- Native output is delivered through a forced `submit_decision_check` tool call and a malformed answer stops Shape with `shape/decision_check_invalid`, as the provider layer has no other structured-output channel. (source: request)
- The `decision_check` event fields, the feedback headline and line format, and the card block heading are fixed here so behavior is observable. (source: request)

## Source comparison
- addressed: opt-in `shape_decision_check: {enabled: true}`, default off, validation like `shape_audit`, documented in docs/configuration.md (scenario 5, config unit test; scenario 4 for off).
- addressed: one fresh read-only call after each complete candidate, after K25 gate and before K20 self-check, native forced tool and external structured result, input only request and candidate intent.md (scenarios 1-3 observe native; external has the integration test below).
- addressed: mechanical substring checks, unsupported for a quote absent from the request (scenario 2), one-list feedback with the exact headline in the same conversation, nothing published until clean, no new limit (scenarios 1-2).
- addressed: `(assumption: …)` Decisions not fed back and listed on the approval card (scenario 3).
- addressed: one `decision_check` event per call with counts per verdict and items; usage counts the calls (scenarios 1-3).
- addressed: must stay — K25 and K20 unchanged; check precedes the step self-check (scenarios assert the event order and one self-check); request/events/usage/card unchanged with key absent (scenario 4).
- clarified: the card-listing is tied to the key being enabled so that the key-absent card stays byte-identical.
- omitted: "All configured checks pass" is the Build's normal gate. Benchmarking against flawed requests is research, outside this Intent. External Shape is not driven by a scripted scenario; an integration test covers it.

## Tests
- config key `shape_decision_check` parses, defaults off, refuses unknown keys and non-Boolean `enabled`: add to `cli/project/config_test.go` (unit)
- mechanical rules (statement not in intent or quote not in request becomes unsupported; assumption items excluded from feedback; headline, N and line format): add table tests in `cli/shape` (unit)
- contradicting Decision fed back, corrected submission published, call sees only request and intent, event with counts and items, usage counts both calls, check precedes self-check: scenario 1 (scenario)
- a quote not in the request is unsupported: scenario 2 (scenario)
- an assumption Decision publishes unfed and is on the approval card: scenario 3 (scenario)
- key absent: no check request, tool, text or event, usage and card unchanged: scenario 4 (scenario)
- unknown key under `shape_decision_check` refused before any provider request: scenario 5 (scenario)
- external Shape runs the check as one fresh read-only session per candidate and applies the same rules: add an integration test in `cli/shape` using the scripted external session (integration)

## Feasibility
- The driver compiles against the unchanged tree as a go -overlay test; with the key absent (mode off) it publishes and the real approval card prints (exit 5) on the unchanged code, and with the key present the unchanged code refuses `unknown key shape_decision_check`, so the enabled scenarios are legitimate missing-feature red. (probe 2: off published with card exit 5; badkey exit 3 with `line 5: unknown key shape_decision_check`)
- The observer's good controls accept and bad controls reject. (probe 3: good exit 0, bad exit 1)
- evidence: {"id":"k26-observer","kind":"observer","inputs":["features/steps/k26_decision_check_driver.go"],"observers":["features/steps/k26_decision_check_steps.js"],"checks":[{"name":"good","command":"\"$KOGEN_NODE\" features/steps/k26_decision_check_steps.js --control good","exit":0,"output":"k26 observer good\n"},{"name":"bad","command":"\"$KOGEN_NODE\" features/steps/k26_decision_check_steps.js --control bad","exit":1,"output":"k26 observer rejected bad fixtures\n"}]}
