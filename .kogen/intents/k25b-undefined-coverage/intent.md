# Cover undefined audit defects by a Decision

Slug: k25b-undefined-coverage
Model: not applicable — one pure coverage predicate; no state machine
Acceptance:
- .kogen/intents/k25b-undefined-coverage/acceptance.feature
- features/steps/k25b_coverage_steps.js
- features/steps/k25b_coverage_driver.go

K25's coverage gate (`uncoveredDefects` in `cli/shape/audit.go`) can never be satisfied by a Decision for an `undefined` defect, because its `result_a`/`result_b` are empty and `strings.Contains(line, "")` is always true. This change makes a Decision able to define the missing name.

## Rule changes (`uncoveredDefects`, `cli/shape/audit.go`)
- `undefined` defects: a line inside `## Decisions` covers the defect when it contains `quote_b` (the missing name) verbatim and a definition marker immediately follows an occurrence of the name, optionally after spaces/tabs: `:`, `=`, or the whole word `means` or `is`. A line that only mentions the name, defines a different name, or has a marker only before the name does not cover it. (A trailing `(source: request)` after other words is not a marker for the name.) `exposing_input`, `result_a` and `result_b` play no part for `undefined` Decisions. The question path is unchanged: a question containing `quote_a` and `quote_b` covers it.
- `conflict` and `precedence` defects keep the existing rule (line contains `exposing_input` and is not one stating both results), except that a line is disqualified only when `result_a` and `result_b` are both non-empty and the line contains both. An empty result never disqualifies a line.

Unchanged: with `shape_audit` off Shape is unchanged; the feedback headline and per-defect line format; no new limit. Existing K25 scenarios keep passing.

## Decisions
- The definition marker must follow the name directly (after optional blanks), so that the `(source: request)` suffix of every Decision cannot count as a definition. (source: request)
- Name and marker matching is exact, case-sensitive substring/whole-word matching, never model judgement. (source: request)
- When only one result is empty, a line is never disqualified, since "both" cannot hold. (source: request)

## Source comparison
- addressed: undefined defect covered by a Decision defining `quote_b`; mention-only does not cover; question with both quotes still covers (scenarios 1-3, unit table).
- addressed: conflict with empty result_b covered by a Decision with the exposing input; precedence likewise (scenario 4).
- clarified: "definition marker such as `:`, `=`, `means`, `is`, after the name" is made precise as immediately after the name, because the `(source: request)` suffix would otherwise always match `:`.
- addressed: must stay — existing K25 scenarios unchanged and untouched (scenario 5 pins the both-results rule); feedback format and limits not edited.
- addressed: "All configured checks pass" is the Build's normal gate.

## Tests
- undefined defect covered by a defining Decision line (`:`, `=`, `means`, `is`); mention-only, other-name and marker-before-name lines do not cover: table test in `cli/shape` (unit); scenarios 1-2 (scenario)
- question with both quotes still covers an undefined defect; with one quote does not: scenarios 2-3 (scenario)
- conflict/precedence with an empty result is covered by a Decision with the exposing input; both-results line still not: scenarios 4-5 (scenario)
- existing K25 behavior (audit call, gate feedback, off mode) stays unchanged: the existing K25 scenarios and tests (existing)

## Feasibility
- evidence: {"id":"k25b-observer","kind":"observer","inputs":["features/steps/k25b_coverage_driver.go"],"observers":["features/steps/k25b_coverage_steps.js"],"checks":[{"name":"good","command":"\"$KOGEN_NODE\" features/steps/k25b_coverage_steps.js --control good","exit":0,"output":"k25b observer good\n"},{"name":"bad","command":"\"$KOGEN_NODE\" features/steps/k25b_coverage_steps.js --control bad","exit":1,"output":"k25b observer rejected bad fixtures\n"}]}
