# Answer Shape's decision check in acceptance

Slug: k-acceptance-decision-check-answer
Model: not applicable — two test fakes give one fixed answer to one request type; there is no state
Acceptance:
- .kogen/intents/k-acceptance-decision-check-answer/acceptance.feature
- features/steps/k-acceptance-decision-check-answer__suite.js

kogen-shaping 1e795ed ("Restore a same-value-aware decision check", Kogen-Intent k-shape-decision-same-value) adds a decision check to every Shape candidate. The only valid answer is one `submit_decision_check` call whose `items` is a list (native). With `executor: claude-code`, it is a structured result object whose `items` is a list. kogen's deterministic acceptance suite (`test/acceptance`) has never answered this check. With kogen rebuilt with kogen-shaping 6a80040 (`v0.0.0-20261104024305-6a80040aa78b`), shaping scenarios fail in two ways:
- The fake ChatGPT server classifies the check as a `build` request and plays the script's build calls, which gives `shape/decision_check_invalid: the decision check answer is not a valid submit_decision_check payload (expected one submit_decision_check call); nothing was published`.
- The fake claude returns the shape round's `{files}` submission, which gives `... (items must be a list)`.

These are the 22 and 5 failures of the 08:01Z window. After this change both fakes answer the check generically, so every scenario that shapes gets a valid answer. No scenario in `spec/features` changes.

The product should behave like this. The Build implements it in `test/acceptance/support/fake-servers.js`, `test/acceptance/fixtures/claude/fake-claude.js` and `spec/features/STEPS.md`:
- **Fake ChatGPT server.** In `handleProvider`, a request whose `tools` include a tool named `submit_decision_check` is Shape's decision check.
  - It is answered apart from the scripted conversation, before the request is classified, like the contract and question checks. It is not added to `requests`, `responses`, `responseItems` or the per-kind counts. So "request <n> contains …" and "the fake ChatGPT server received <n> requests" see the same requests as without a decision check.
  - The answer is one streamed `submit_decision_check` function call with arguments `{"items":[]}`, using a response id and call id that are unique within the scenario.
  - It is followed by `response.completed` with usage `{"input_tokens":0,"input_tokens_details":{"cached_tokens":0},"output_tokens":0,"output_tokens_details":{"reasoning_tokens":0}}`. kogen-shaping adds the decision check's tokens to the Shape usage line. Zero usage keeps the totals that scenarios pin unchanged, e.g. `shape {model}/{effort} input=500 cached=25 output=100 reasoning=50` in "A question the check does not class as UI/UX goes back to the shaper and is not asked" (evidence: spec/features/02-shaping.feature). The contract and question checks' usage (100/5/20/10) would raise those totals.
- **Fault script `shape-decision-check-without-call`.** Under this new script name, the decision check gets one assistant text message and no function call, with the same zero usage and the same exclusion from requests and counts. Shape requests under it are answered as under `shape-ready-is-even`, which is the default branch of `shapeResponse`. kogen-shaping then stops with `shape/decision_check_invalid: the decision check answer is not a valid submit_decision_check payload (expected one submit_decision_check call); nothing was published` on stdout (exit 1).
- **Fake claude.** In `fake-claude.js`, an invocation is Shape's decision check when the `properties.items.items.properties` of its `--json-schema` contain both `statement` and `verdict`.
  - It is recognised before the question-check answer, whose schema also has `items`. It is answered apart from the scripted roles, like the contract check: an init event, then a successful `result` with `structured_output` `{"items":[]}`, usage `{"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":0}` and `total_cost_usd` 0.
  - It does not advance the `calls` or per-role counters, and it writes no prompt, argv, session, tool-call, wakeup-evidence or cost record. So "fake claude role "shape" ran <n> invocations" and the session steps are unchanged.
- **`spec/features/STEPS.md`.** Document both answers:
  - one sentence at the end of the **Fake claude.** paragraph;
  - one paragraph after the paragraph that begins `Shape's question check (SHP-6) is answered apart`;
  - a row for `shape-decision-check-without-call` in the script table.

  Add no new requirement id: `spec/tools/check.mjs` requires every id to be defined.

The empty list is the smallest valid answer. It states no decision item, so the check reports no problem and the candidate goes on (evidence: kogen-shaping v0.0.0-20261104024305-6a80040aa78b shape/decision.go parseDecisionCheck and decisionOutcome). The fakes recognise the check only by its tool name (native) or its schema (claude). Acceptance pins neither the check's prompt text nor its payload wording.

Boundaries:
- There is no production change. `cli/` is unchanged, including `cli/go.mod` and `cli/go.sum`.
- Those two files are protected (`protect` in `.kogen/project.yaml`), so this Build cannot bump kogen-shaping. Kogen's component adoption makes that bump outside Build, as commit d98cfe0 "Adopt component versions" did. Until then the new answers stay dormant at the current pin f04edcea9896, which has no decision check.
- Acceptance therefore runs the suite against kogen rebuilt with kogen-shaping 6a80040 in a disposable copy.
- Other fake behaviour, every `spec/features/*.feature` file and the spec prose stay unchanged.

## Decisions
- kogen's acceptance scripted provider answers Shape's decision check with one submit_decision_check call whose items are a list. The answer is generic for every scenario that shapes, not edited scenario by scenario. (source: request)
- Acceptance asserts only kogen's outcomes. It does not pin the decision check's prompt text or its exact payload wording beyond what a valid answer needs. (source: request)
- No production change in kogen. (source: request)
- A scripted answer with no submit_decision_check call still produces decision_check_invalid. (source: request)
- The kogen-shaping bump in cli/go.mod is left to component adoption outside Build, because cli/go.mod and cli/go.sum are protected. Acceptance instead runs the suite against kogen rebuilt with kogen-shaping 6a80040 in a disposable copy. (evidence: .kogen/project.yaml) (source: request)
- The decision check answers carry zero token usage and zero cost, so the usage totals that scenarios already pin stay unchanged. (evidence: spec/features/02-shaping.feature; test/acceptance/support/fake-servers.js) (source: request)

## Source comparison
- Addressed Problem: both failure messages were reproduced locally against `dist/kogen-855340eb-darwin-arm64.tar.gz` with kogen rebuilt with kogen-shaping 6a80040:
  - "A question the check does not class as UI/UX goes back to the shaper and is not asked" failed with exit 1 after `kogen: decision check response input=100 …`, because the fake answered the check as a build request.
  - "Claude lineup shapes builds reviews and signs one exact-tree commit" failed with `shape/decision_check_invalid: … (items must be a list)`.
- Excluded, as the request says: the review-card SHA-256 reds belong to K-ACCEPTANCE-NO-CARD-HASH, which has already landed (cecf691).
- Addressed Need 1 (one submit_decision_check call with an items list, generic): both fakes recognise the check by its tool or schema, for every script and fake claude script.
- Addressed Need 2 (assert only kogen's outcomes, lesson 4): the acceptance judges scenario results and kogen's own stop message. It does not judge the check's prompt or payload text.
- Need 3, partly conflicting with the protection contract: "No production change in kogen" is kept. "Bump kogen-shaping in cli/go.mod to a version at or after 1e795ed" cannot be done by this Build, because `cli/go.mod` and `cli/go.sum` are protected and no override exists. Kogen's component adoption in this repository owns that pin. The requirement "so the suite runs against it" is met by the Intent's acceptance, which rebuilds kogen with kogen-shaping 6a80040 in a disposable copy (offline from the module cache in about 1.4 s).
- Acceptance 1 ("no decision_check_invalid failures with kogen-shaping at 6a80040"): the Intent runs five representative shaping scenarios against the 6a80040 rebuild, and the same five against the current pins:
  - native ready Intent;
  - native answers;
  - native question-check refusal, with its pinned `input=500` total and 3 requests;
  - claude full lineup;
  - claude questions.

  Not every scenario of the full suite runs in Intent acceptance, because approval bounds the acceptance command at 120 seconds. The complete suite against such a rebuild (`npm test` in `test/acceptance` with `KOGEN_ARCHIVE`) remains the adoption/release check. "Or current main" is not separately run: shaping 3696dba and dad08fc have a byte-identical `shape/decision.go`.
- Acceptance 2 (fault test): the `shape-decision-check-without-call` script, run in a generated feature against the 6a80040 rebuild, must still end with `shape/decision_check_invalid … (expected one submit_decision_check call)`.
- Acceptance 3 (go test passes): this is the configured `go-test` check. The Build changes no Go code.
- Automatic-retry cause (`shape/protected_conflict: required edits touch protected files: cli/go.mod, cli/go.sum`): this Intent requires no protected edit (see Need 3).
- Periodic-attempt cause (`candidate/review_blocked`: an unmet requirement "the same usage object the other check answers send"): that earlier contract was wrong. kogen-shaping 6a80040 adds `decisionUsage` to the Shape usage line (shape/shape.go:691), so non-zero usage changes totals that scenarios pin. This Intent requires zero usage and runs exactly that scenario. The finding belongs to this repository's Intent, not to kogen-shaping.

## Tests
- The native fake answers the decision check with one submit_decision_check call and an items list, outside request numbering and counts and with zero usage: the Intent scenario "Shaping scenarios pass with kogen-shaping 6a80040" runs the 02-shaping rows (ready Intent, answers, and question-check refusal with `input=500` and 3 requests) against the 6a80040 rebuild (scenario)
- The fake claude answers the decision check's schema with `{"items":[]}` outside its role counters and sessions: the same Intent scenario runs the two claude-code-full-lineup rows (scenario)
- The suite at kogen's current pins is unchanged: "The same shaping scenarios still pass with kogen's current pins" (regression)
- A scripted answer with no submit_decision_check call still produces decision_check_invalid, and that answer is not counted as a request: "A decision check answer without a submit_decision_check call still stops Shape" (regression)
- kogen's go test passes: the configured `go-test` check, `(cd cli && GOFLAGS=-trimpath go test ./...)` (existing)
- STEPS.md stays consistent with the spec tooling: the configured `spec` check, `(cd spec && sh check.sh)` (existing)

## Feasibility
- `go mod edit -require=github.com/KogenAI/kogen-shaping@v0.0.0-20261104024305-6a80040aa78b` followed by `go build` in a disposable copy of `cli/` built offline (`GOPROXY=off`, `GOFLAGS=-mod=mod`) in 1.4 s. `go version -m` showed shaping 6a80040 with every other pin unchanged. kogen-shaping 6a80040 itself requires only older coordinator, executor and verification versions.
- Against that rebuild and the unchanged tree:
  - "A question the check does not class as UI/UX goes back to the shaper and is not asked" failed with exit 1 after `kogen: decision check response input=100 cached=5 output=20 reasoning=10`.
  - "Claude lineup shapes builds reviews and signs one exact-tree commit" failed with `shape/decision_check_invalid: … (items must be a list)`.

  Both ran in 7.5 s.
- With the current pins, the five listed scenarios passed in 14 s with `--parallel 4`.
- A feature file in a temporary directory outside `test/acceptance`, given by absolute path, ran under the suite's steps and hooks in 4.3 s. Against the 6a80040 rebuild, kogen printed the `(expected one submit_decision_check call)` stop on stdout, and the Intent folder remained (so the generated fault feature does not assert its absence).
- kogen-shaping 6a80040's `parseDecisionCheck` accepts `{"items":[]}`, and `decisionOutcome` then returns no problem lines. `shape/decision.go` is identical in 6a80040, dad08fc and 3696dba.
- evidence: {"id":"suite-observer","kind":"observer","inputs":["features/steps/k-acceptance-decision-check-answer__suite.js"],"observers":["features/steps/k-acceptance-decision-check-answer__suite.js"],"checks":[{"name":"good","command":"node features/steps/k-acceptance-decision-check-answer__suite.js --control good","exit":0,"output":"observer accepted\n"},{"name":"bad","command":"node features/steps/k-acceptance-decision-check-answer__suite.js --control bad","exit":1,"output":"observer rejected\n"}]}
