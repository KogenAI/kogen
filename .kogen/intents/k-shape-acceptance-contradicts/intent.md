# Check acceptance examples against Intent rules

Slug: k-shape-acceptance-contradicts
Model: not applicable — one more gate in the existing Shape submission pipeline and one hash-bound record that approval reads; no new state machine
Acceptance:
- .kogen/intents/k-shape-acceptance-contradicts/acceptance.feature
- features/steps/k_shape_acceptance_contradicts_steps.js

Fix K-SHAPE-ACCEPTANCE-CONTRADICTS (change_type: fix; Studio kogen issue 42502600-d8e4-4042-97f5-978dde341b1d). Today Shape publishes a candidate whose acceptance examples contradict its own Intent: in 9 of 100 finished research Builds no correct implementation could pass the protected acceptance (for example 5430 seconds expected as "1 hour, 1 minute, 30 seconds", although it is 1 h 30 min 30 s), and the Build ended `candidate/build_blocked` or landed code matching the wrong fixture. Readiness cannot see this: it only runs the scenarios, and an example whose expected value does not follow from its input still parses and runs.

After this change every Shape (native and external `executor: claude-code`) runs an **example check** on every complete candidate, and a contradiction goes back to the shaper or stops Shape with a clear reason; a package left by such a stop is refused by `kogen intent approve`. The check reads only text: the request, the candidate `intent.md` and the candidate `acceptance.feature` (scenarios and Examples rows). It never reads or judges step definitions or what step code can express. A model derives values; Kogen alone decides, by the mechanical rule below. No new command, flag, option or setting; no timeout, retry or limit change. Correct examples keep passing: an example is refused only when its expected value differs from the derived value.

## The example check call
- When: inside `checkSubmission` (`cli/shape/shape.go`), for every submission of files whose accumulated candidate passed the existing validation, Intent checks and fixers: after the fixers and after the opt-in decision check (K26) when it is enabled, before the step self-check (K20) and readiness. Questions and blocked submissions are not checked. A candidate whose formatted `intent.md` and `acceptance.feature` are byte-identical to a candidate already checked without a contradiction in the same invocation (for example an acknowledgment resubmission) is not checked again: no request and no event.
- Native: one fresh provider request on the shape role and route, with no other conversation state, whose **only** tool is `submit_example_check` (strict JSON schema below). Its input is one user message: `Slug: <slug>`, then `# Request` with the request text (`state.Request`), then `# Candidate intent.md` with the complete file, then `# Candidate acceptance.feature` with the complete file, as formatted on disk; nothing else (no README, step files, navigation, Q&A or repository context). Progress line `kogen: checking the acceptance examples`. Read-only: no other tool. Its tokens are added to the usage total Shape prints, like the decision check.
- External (`executor: claude-code`): one fresh read-only session per check with the same input and the same schema as its structured result (executor directory `executor-example-<n>` beside the decision check's); its rounds count in the usage line's round count.
- Instructions to the model: for every scenario and every Examples row that states a concrete expected result for a concrete input, give one item; copy `scenario` (the scenario name), `input` and `expected` exactly from `acceptance.feature`, copy `rule` exactly from `intent.md` or the request (the rule that determines the expected value), compute `derived` yourself, step by step, as the value that rule gives for that input, written in the same form as `expected`, and give the computation in `why`. Judge only stated inputs, expected values and rules, never step code. Answer by calling `submit_example_check`.
- Payload: `{"examples":[{"scenario":string,"input":string,"expected":string,"rule":string,"derived":string,"why":string}]}`, every field required, no other field. An answer that is not exactly one valid `submit_example_check` payload stops Shape with `shape/example_check_invalid: the example check answer is not a valid submit_example_check payload (<why>); nothing was published` (exit 1). Provider failures follow the existing Shape provider-failure path.

## Mechanical rule (no model judgement)
Normalize a text by turning every run of spaces, tabs, CR and LF into one space and trimming (the existing `normalizeWhitespace`). For each item, in the order returned:
- `unquoted`: `scenario`, `input` or `expected` is empty after normalization or not a substring of the normalized candidate `acceptance.feature`, or `rule` is empty or a substring of neither the normalized candidate `intent.md` nor the normalized request. Unquoted items are recorded but never fed back and never refuse a candidate.
- `contradicts`: quoted, and the normalized `derived` differs from the normalized `expected`.
- `follows`: otherwise.

With one or more `contradicts` items, nothing is published for this submission and its tool result (external: the next round's feedback) is exactly the headline
`Example check: <N> acceptance example(s) contradict the Intent's rules; nothing was published. Correct the expected value, the input or the rule so that each expected value follows from its input under the Intent's rules; do not remove or weaken an example to pass this check.`
(N = number of contradicting items) followed by one line per contradicting item, in order, exactly
`- scenario: <scenario> | input: <input> | expected: <expected> | rule: <rule> | derived: <derived> | why: <why>`
with the values as returned, joined by single newlines. It is an invalid submission under the existing rules: the problems are those item lines, a `submission_refused` event with gate `example_check` is recorded, accumulated proposals stay as for other feedback, and the next candidate is checked again. There is no last-attempt pass-through: at the third invalid submission in a row Shape ends as today with `intent/not_ready: the Intent is not ready to build` and the item lines (exit 1), and the files of that last attempt stay (SHP-4). No contradiction: the candidate goes on to the step self-check and readiness unchanged.

Each check records one event in the shaping `events.ndjson`: `{"event":"example_check","follows":<n>,"contradicts":<n>,"unquoted":<n>,"items":[{"scenario","input","expected","rule","derived","why","result"}]}`, `result` being `follows`, `contradicts` or `unquoted` and the counts those of the items.

## Approval of a package Shape left contradicting
When Shape ends `intent/not_ready` and its last refused submission was refused by the example check, it writes `.kogen/local/shaping/<slug>/example-contradictions.json` (0600 file in the existing 0700 shaping directory): `{"sha256":"<the package hash kogen intent approve shows, of the files left on disk>","lines":[<the item lines>]}` and a newline. Shape of that slug ending ready removes the file. `kogen intent approve <slug>` (card and hash forms) reads it after the existing pending-questions and Intent-directory checks and after computing the current package hash, before comparing a given hash and before readiness: when it parses and its `sha256` equals the current hash, approval refuses with `intent/examples_contradict: Shape's example check found acceptance examples that contradict the Intent's rules; correct the examples or the rules in the Intent's files, or delete .kogen/intents/<slug>/ and shape again` followed by its lines, each printed indented by two spaces (exit 1); it writes no approval marker and changes nothing. A record whose hash differs (the files were edited) or that does not parse does not affect approval.

## Unchanged and out of scope
- Readiness, acknowledgment, publication, the step self-check (K20), the request audit (K25) and the decision check (K26) are unchanged; Refine is unchanged and runs no example check.
- Judging step code or whether a step can express a rule (for example signed zero under strict JSON equality) is out of scope.
- Native Shape now makes one more provider request per complete candidate. The Build updates the scripted providers of the Go tests in `cli/` that it runs so they answer the check request (for example a default route in `cli/shape/helper_test.go`); accumulated acceptance suites of earlier Intents under `features/steps/` are not run by the configured checks and are not changed by this Intent.
- `spec/prose/02-shaping.md` SHP-8 describes the example check (it names `submit_example_check`, the feedback and the not-ready ending) and the approval refusal `intent/examples_contradict`.

## Decisions
- Before an Intent is ready, each acceptance example's expected value must follow from its stated input under the rules stated in the Intent or the request; a contradiction goes back to the shaper with the scenario, input, expected value, rule and derived value named, and nothing is published until none remains (source: request)
- A contradiction still present when Shape stops is not marked ready, and `kogen intent approve` refuses that unchanged package with a clear reason instead of letting a Build end build_blocked (source: request)
- The check reads only the Intent, request and scenario/Examples text and never judges step code (source: request)
- A model derives the values; Kogen decides by comparing derived and expected values of quoted examples only, so a consistent example is accepted unchanged and acceptance is never weakened to pass (source: request)
- No new command, flag, option or setting, and no timeout, retry or limit change; the check always runs (source: request)

## Source comparison
- addressed: Need "each expected value follows from the scenario's input under the Intent's stated rules" — the example check call and mechanical rule; scenarios 1-4.
- addressed: Need "found at shape or approve time (and goes back to the shaper or stops with a clear reason)" — feedback in the same conversation (scenarios 1-3), `intent/not_ready` at the third submission and `intent/examples_contradict` on the card and with the full hash, no approval marker (scenario 5).
- addressed: Need "Correct examples keep passing; shaping does not get weaker acceptance" — consistent versions published byte-identical (scenarios 1-4); unquoted items never refuse; the headline forbids removing or weakening examples.
- addressed: acceptance evidence and 1 Nov constraint — the installed release's real `kogen intent shape` and `kogen intent approve` against a scripted provider returning prepared packages, asserting printed output, exit codes, files on disk, events and requests; the scripted check returns only quotes and a derived value that the steps recompute from the rule, the verdict is Kogen's; arithmetic (5430 seconds, "1 hour, 1 minute, 30 seconds" vs "1 hour, 30 minutes, 30 seconds"), fixed-width columns 10-13 (input giving -1.20, fixture expecting -12.00) and ordering opposite to the stated bytewise order, each paired with its consistent version (scenarios 1-4). No Go test names are required by acceptance.
- addressed: scope narrowed — the check reads the Intent and scenario/Examples text only; prepared packages use trivial steps; no step-expressiveness requirement.
- addressed: "No new command, flag or option; no timeout, retry or limit change" — none added; existing three-submission rule kept.
- omitted: signed zero under strict equality (step code semantics, out of scope per the constraint).
- omitted: location, recurring-rule and duplicated-usage-text kinds are covered by the same general rule but not exercised; the trailing-space kind is not detected, as derived and expected are compared after whitespace normalization.
- omitted: Refine runs no example check; the measured contradictions were written by Shape.
- omitted: issue id, Build ids f8138a9a and 50f9429b and the 9-of-100 measurement are evidence, not behavior.

## Tests
- a contradicting arithmetic, fixed-width and ordering example goes back to the shaper with the exact headline and item line, nothing is published, and the consistent resubmission is published byte-identical, ready, with a card listing it: scenarios 1-3 (regression)
- a consistent example is accepted unchanged after exactly one check request offering only submit_example_check and carrying the request, intent.md and acceptance.feature, with one follows event: scenario outline 4 (scenario)
- a contradiction kept to the third submission ends Shape intent/not_ready with the item line, no readiness evidence or receipt, and approve card and full-hash approval refuse with intent/examples_contradict and write no marker: scenario 5 (regression)
- the mechanical rule (normalized substring quotes, rule found in intent.md or the request, empty quotes unquoted, unquoted never fed back, normalized derived vs expected, event counts, headline N and line format): table tests in cli/shape (unit)
- an answer that is not one valid submit_example_check payload stops Shape with shape/example_check_invalid and publishes nothing: a scripted-provider test in cli/shape (integration)
- an identical candidate already checked without a contradiction is not checked again, and the check's tokens are in the printed usage total: a scripted-provider test in cli/shape (integration)
- external Shape runs the check as one fresh read-only session per candidate with the same rule: a test with the scripted external session in cli/shape (integration)
- the contradictions record is written at the not-ready stop, removed when Shape ends ready, and does not block approval once the package hash differs: a test in cli/shape/approve_test.go (integration)
- existing scripted-provider Go tests keep passing with an answer for the check request: the updated existing tests (existing)
- SHP-8 names submit_example_check and intent/examples_contradict: scenario 6 (scenario)

## Feasibility
- Draft acceptance against the unchanged HEAD release (scratch copy outside the checkout, KOGEN_ARCHIVE=dist/kogen-ee9100a1-darwin-arm64.tar.gz): all 8 scenarios fail for the missing feature only — each contradicting first submission is published ready at once (exit 0, no check request, no feedback), consistent ones get 0 check requests, the kept contradiction exits 0 and its full-hash approval prints `approved durations 7ce0ffac`, and SHP-8 lacks the names; 32.7 s.
- The consistent outline without its two new-check steps passes all 3 rows on the unchanged release (Next line, byte-identical published files, card line `(passes now)`), so the masked later steps observe real output; 15.6 s.
- The observer controls accept the known-good observations and reference derivations and reject every known-bad one (good exit 0, bad exit 1).
- evidence: {"id":"example-check-observer","kind":"observer","inputs":["features/steps/k_shape_acceptance_contradicts_steps.js"],"observers":["features/steps/k_shape_acceptance_contradicts_steps.js"],"checks":[{"name":"good","command":"\"$KOGEN_NODE\" features/steps/k_shape_acceptance_contradicts_steps.js --control good","exit":0,"output":"accepted\n"},{"name":"bad","command":"\"$KOGEN_NODE\" features/steps/k_shape_acceptance_contradicts_steps.js --control bad","exit":1,"output":"rejected\n"}]}
