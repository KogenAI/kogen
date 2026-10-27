# Flag timeout, retry and limit raises in review

Slug: k14-review-limit-raises
Model: not applicable — the change is one static instruction paragraph sent to a reviewer; there is no state machine
Acceptance:
- .kogen/intents/k14-review-limit-raises/acceptance.feature
- features/steps/k14_limit_raises_steps.js
- features/steps/k14_limit_raises_driver.go

Kogen's independent Review gets one more rule in its instructions, so that a change which raises a timeout, retry count or limit without a profile is a blocking finding. The rule applies to both review routes: the native reviewer (its instructions, `agent.Prompt(agent.Reviewer)` and every request built from them) and the external executor reviewer (the review task text appended to the authority in `cli/build/review_external.go`, `reviewTask`). Kogen does not pre-compute findings: the rule is static text, and the reviewer sees the raise in the diff it already receives.

The exact rule text (one paragraph, settled literal) is:

`Limit raises: a change that raises a timeout, deadline, retry or attempt count, size or count limit, or wait duration (in code, configuration, tests or scripts, including go test -timeout, Playwright or cucumber timeouts and ExUnit timeouts) is a blocking finding unless the Intent, or a profile cited in the change, shows that the extra work is needed and cannot be removed. The finding names the file:line, the old and new value, and asks for the profile or a speed-up. Lowering a limit, or adding a new bound where none existed, is not flagged by this rule.`

The rule text lives in exactly one place in the Go source (for example one exported constant in `cli/agent`), and both routes use it: the native reviewer instructions are the existing reviewer prompt plus that paragraph, and the external review task includes that same paragraph. It must appear exactly once in each route's review request. The Claude Code `ReviewConstraints` need not change. Existing tests that pin the reviewer prompt bytes/hash (`cli/agent/prompts_test.go`, `cli/agent/testdata/prompts_golden.json`) and anything that identifies reviewer requests by their instructions must be updated for the added rule only.

Unchanged: the verdict format and schema (`submit_review`, `defs.go`), the round rules, retries and limits of review, and every other reviewer rule. No new review round, retry or limit is added. Request bytes change only by the added rule.

## Decisions
- The rule is blocking unless the Intent or a profile cited in the change shows the extra work is needed and cannot be removed; the finding names file:line, old and new value, and asks for a profile or a speed-up (source: request)
- Lowering a limit, or adding a new bound where none existed, is not flagged (source: request)
- One shared rule text for native and external review; no new round, retry or limit; verdict format, schema and round rules unchanged (source: request)
- Kogen does not pre-compute findings; the acceptance is that the rule is included in the review request for the raising diff (source: request)

## Source comparison
- Request item 1 (rule in native and external Review instructions, covering code, config, tests, scripts, go test -timeout, Playwright/cucumber/ExUnit timeouts, blocking unless Intent/profile, finding names file:line, old/new value, asks for profile or speed-up): addressed by the exact rule paragraph above and scenarios for both routes.
- Request item 2 (lowering or a new bound is not flagged): addressed by the last sentence of the rule, present in both requests.
- Request item 3 (one place, no new round/retry/limit): addressed by the single shared constant requirement; no new round is added, and the acceptance builds each route once with exactly one review request.
- Must stay (verdict format, schema, round rules, no other rule changed, request bytes change only by the added rule): addressed in prose; Tests lists a unit test pinning the reviewer prompt as the old prompt plus the rule.
- Acceptance 1 (fake reviewer route records instructions containing the rule for native and external): addressed by the scripted provider and scripted executor in the driver.
- Acceptance 2 (fixture diff raising `timeout: 600` to `timeout: 1800` with no profile): addressed; the packet naming the raise is omitted as a pre-computed finding because Kogen does not pre-compute findings, so the rule and the diff carrying the raise are asserted instead.
- Acceptance 3 (all configured checks pass): addressed by the normal Build gate.
- Host safety: addressed; the driver uses local fakes, synthetic credentials, no process-name stopping, no CPU load.

## Tests
- The native reviewer's instructions contain the rule exactly once for a diff raising `timeout: 600` to `timeout: 1800` with no profile: scenario in acceptance.feature through a real Build with a scripted provider (scenario)
- The external reviewer's request contains the same rule exactly once for that diff, and both requests carry the raise: scenario in acceptance.feature through a real Build with a scripted executor (scenario)
- Lowering a limit or adding a bound is not flagged: the rule text includes that sentence, asserted verbatim in both routes (scenario)
- The reviewer prompt is the previous prompt plus only the rule, and the verdict schema is unchanged: update `cli/agent/prompts_test.go` and its golden data so the reviewer prompt without the rule equals the old bytes, and the schema hash stays (unit)
- The external review task includes the shared rule and no new round: extend the existing external review test in `cli/build/review_lineup_test.go` to assert the brief contains the rule once and one review round (integration)

## Feasibility
- The acceptance observation was run in scratch against the unchanged tree: both the native and the external routes built, landed with one review request each, and carried the raised diff (`-timeout: 600`, `+timeout: 1800`); the rule is absent there, which is the legitimate missing-feature red. (probe 1: exit 0, 8.3 s)
- evidence: {"id":"k14-observer","kind":"observer","inputs":["features/steps/k14_limit_raises_steps.js"],"observers":["features/steps/k14_limit_raises_steps.js"],"checks":[{"name":"good","command":"node features/steps/k14_limit_raises_steps.js --control good","exit":0,"output":"k14 observer good\n"},{"name":"bad","command":"node features/steps/k14_limit_raises_steps.js --control bad","exit":1,"output":"k14 observer rejected bad fixtures\n"}]}
