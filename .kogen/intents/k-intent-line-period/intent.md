# Accept a trailing period on Tests and Decisions

Slug: k-intent-line-period
Model: not applicable — two line-grammar rules of a stateless validator; no state machine or interacting rules
Acceptance:
- .kogen/intents/k-intent-line-period/acceptance.feature
- features/steps/k_intent_line_period_steps.js
- features/steps/k_intent_line_period_driver.go

The Intent check (`project.CheckIntent`, `lintIntent` in `cli/project/intent.go`) refuses a `## Tests` line or a `## Decisions` item whose only deviation from the grammar is one sentence period after the closing parenthesis (Kogen issue a2f1c80c: 2,597 of 2,659 recorded tests-line problems were otherwise-valid lines ending in ".", 2,427 of them exactly "(layer)."; each costs the shaper a retry turn, and one of 20 AoR base shape cells on e746e82 ended refused because of it). After this change such a line passes, and the same line without the period still passes. Nothing else is loosened: every other malformed line fails exactly as now, with the same problem text.

The grammar after this change (the only production edits are these two expressions in `cli/project/intent.go`, plus the spec sentence below):
- Tests line: `testLineRe` becomes `^- (none: \S.*|.+: .+ \((unit|integration|scenario|regression|existing)\)\.?)$`. The optional period must follow the closing parenthesis immediately and end the line: "(unit)." passes; "(unit)..", "(unit). Extra words", "(unit) .", "(unit)!" and "(unit) and more" fail; a missing or unknown layer, a missing rule (no `<rule>: `) and a missing test still fail. The `- none: <reason>` form is unchanged. The problem line stays exactly `tests: <line> must be ` + "`- <rule>: <test to add or update> (<layer>)` or `- none: <reason>`".
- Decisions item: `sourceRe` becomes `\(source: (request|answer \d+)\)\.?\s*$`: one optional period directly after the closing parenthesis, then the trailing whitespace that is already allowed today. "(source: request)." and "(source: answer 12)." pass; no source, `answer x`, an unknown source such as `caller`, "(source: request.)", "(source: request)..", "(source: request). Extra", "(source: request) ." and "(source: request)!" fail. The problem line stays exactly `decisions: a decision has no source`.

How the stored Intent records the line: exactly as the shaper submitted it. Kogen does not rewrite, strip or add the period in Shape, Refine or approval; the published `intent.md` keeps the submitted bytes (fixers aside, as today), so the approval hash covers what the shaper wrote.

Specification: `spec/prose/02-shaping.md` states the Tests grammar in the paragraph that begins "`## Tests` lists, for each behavioral rule". Append to the end of that paragraph, as its last sentence and verbatim: "A `## Tests` line or a `## Decisions` item may end with one period directly after its closing parenthesis; Kogen accepts it with or without that period and keeps the line as written." No other spec prose, Gherkin or Quint states this grammar, so nothing else in `spec/` changes.

Unchanged: the shaper prompt (`cli/agent/prompts/shaper.md`) keeps recommending the form without a period; the opt-in decision check's own source-tag handling in `cli/shape/decision.go` (`sourceTagRe`) is not part of this change; no new CLI command, flag, config key, event or output line; no timeout, attempt budget or limit is raised. Every existing contract and conformance test keeps passing unchanged (the golden Elixir Intent cases contain no line whose outcome changes under the new expressions).

## Decisions
- The stored Intent keeps each line exactly as submitted, with or without the period; Kogen never normalizes it. (source: request)
- Exactly one period, directly after the closing parenthesis, is accepted; any other trailing text or punctuation still fails. (source: request)
- The problem texts for malformed Tests and Decisions lines are unchanged. (source: request)
- The spec gains one sentence at the end of the `## Tests` grammar paragraph of `spec/prose/02-shaping.md`, worded as stated above. (source: request)

## Source comparison
- addressed: a Tests or Decisions line valid apart from one trailing period passes, and so does the same line without it: scenarios 1 and 2 (every layer with a period, `none:`, `request` and `answer <n>` with and without the period).
- addressed: malformed lines still fail exactly as now (missing or unknown layer, missing rule or test, missing or wrong source, any other text after the parenthesis, including two periods, a spaced period and other punctuation): scenarios 1 and 2 assert the exact unchanged problem text per line; no gate weakened.
- addressed: how the stored Intent records the line: decided as kept verbatim; scenario 3 runs native Shape with a scripted provider and asserts the published intent.md equals the submitted bytes, published on the first submission with no `submission_refused` event, and the approval card exits 5.
- addressed: a designed contract test for these line forms: new cases in `TestCheckIntentRules` (`cli/project/intent_test.go`); every existing contract and conformance test keeps passing (existing).
- addressed: spec agreement: the spec clause stating the Tests grammar (`spec/prose/02-shaping.md`) gains the stated sentence; scenario 4 checks it. SHP-5 refers to "the form above" and needs no separate edit.
- addressed: synthetic cases only; no new CLI command, flag or config key; no raised timeouts.
- omitted: the opt-in decision check's `sourceTagRe` in `cli/shape/decision.go`; the request names only the validator rules at `cli/project/intent.go:242-243`.
- evidence only: Kogen issue a2f1c80c and research notes fbprobes-20261102 "Wave 2" are not in this checkout; the issue's counts are quoted from the request.

## Tests
- A Tests line valid apart from one trailing period passes, with and without the period, for every layer: add cases to TestCheckIntentRules in cli/project/intent_test.go (unit)
- A Decisions item ending in (source: request) or (source: answer n) passes with and without one trailing period: add cases to TestCheckIntentRules in cli/project/intent_test.go (unit)
- Malformed Tests lines (no or unknown layer, no rule, no test, two periods, spaced period, other text or punctuation after the parenthesis) fail with the unchanged problem text: add cases to TestCheckIntentRules in cli/project/intent_test.go (unit)
- Malformed Decisions items (no source, answer x, unknown source, period inside, two periods, spaced period, other text after the parenthesis) fail with the unchanged problem: add cases to TestCheckIntentRules in cli/project/intent_test.go (unit)
- Native Shape publishes period-ended lines on the first submission and stores them verbatim: acceptance scenario 3 (scenario)
- The spec states the accepted trailing period: acceptance scenario 4 (scenario)
- Earlier Intent rules, golden Elixir Intent cases and Shape lint feedback stay unchanged: the existing tests in cli/project and cli/shape (existing)

## Feasibility
- Scratch observation outside the checkout (go test -overlay mounting the driver as ./shape TestKLinePeriodObservation): on the unchanged tree "(unit)." and "(source: request)." are refused, and Shape's first submission is refused with both problems; with only the two expressions above overlaid, scenarios 1 to 3 pass and the published intent.md equals the submitted bytes.
- evidence: {"id":"k-line-period-observer","kind":"observer","inputs":["features/steps/k_intent_line_period_driver.go"],"observers":["features/steps/k_intent_line_period_steps.js"],"checks":[{"name":"good","command":"\"$KOGEN_NODE\" features/steps/k_intent_line_period_steps.js --control good","exit":0,"output":"k-line-period observer good\n"},{"name":"bad","command":"\"$KOGEN_NODE\" features/steps/k_intent_line_period_steps.js --control bad","exit":1,"output":"k-line-period observer rejected bad fixtures\n"}]}
