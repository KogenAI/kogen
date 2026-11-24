# Distinguish Claude auth probe errors from logout

Slug: readiness-claude-auth-probe-errors
Model: not applicable — this is stateless classification of a probe result and JSON decoding, with no new persistent state or transitions
Acceptance:
- .kogen/intents/readiness-claude-auth-probe-errors/acceptance.feature
- features/steps/readiness-claude-auth-probe-errors__steps.js
- features/steps/readiness-claude-auth-probe-errors__driver/main.go
- features/steps/readiness-claude-auth-probe-errors__driver/observe.cjs

Fix evidence ev-d5397b30 in cli/readiness/readiness.go and add regression coverage in cli/readiness/readiness_test.go. Replace the conflation of failed or malformed auth status responses with confirmed absence of subscription sign-in. Report unavailable or invalid auth status separately while keeping readiness failed when sign-in cannot be established. Preserve the existing confirmed-logout message and login fix, and valid claude.ai subscription readiness. Production edits are limited to these two files. Changing Claude Code version pinning, token custody, or supported sign-in routes is out of scope.

## Decisions
- A successful auth status response with loggedIn false retains the existing no-subscription-sign-in message and login fix. (decision: D1, round 1) (evidence: cli/readiness/readiness.go; cli/readiness/readiness_test.go) (source: request)
- A nonzero auth status probe reports that status could not be checked and does not claim the user is logged out, while keeping the readiness check failed when sign-in cannot be established. (decision: D2, round 1) (evidence: cli/readiness/readiness.go) (source: request)
- Malformed auth status JSON is reported as an invalid or unavailable status result and keeps readiness failed; a valid claude.ai subscription response remains ready. Do not require an exact new diagnostic sentence, only an auth-status-specific explanation of the unavailable or invalid result rather than a logout claim. (decision: D3, round 1) (evidence: cli/readiness/readiness.go; cli/readiness/readiness_test.go) (source: request)
- Keep production changes in cli/readiness/readiness.go and cli/readiness/readiness_test.go, preserving version pinning, token custody and supported sign-in routes. Exercise readiness.Run with readiness.Input and readiness.Text, the public report entry points used by init, using a temporary managed runtime fixture with the existing test-origin seam and no stored token; inspect the models Check and rendered report rather than unrelated install or Git checks. (decision: D4, round 1) (evidence: cli/readiness/readiness.go; cli/readiness/readiness_test.go; cli/readiness.go; cli/init_readiness_test.go) (source: request)

## Source comparison
- Addressed: Request Evidence ev-d5397b30 identifies discarded probe errors and malformed JSON conflated with not signed in, and missing failed/malformed coverage. The outcome paragraph, D2–D3, the nonzero and malformed scenarios, and the required regression tests replace that conflation without introducing a new authentication route.
- Addressed: Request Expected requires unavailable or invalid status to be separate from confirmed logout, while readiness still fails when sign-in cannot be established. D1–D3 and all four executable scenarios distinguish those outcomes, including failure despite a nonzero probe emitting otherwise signed-in JSON.
- Addressed: Request Acceptance 1 preserves the existing no-subscription-sign-in message and login fix for successful loggedIn false. The confirmed-logout scenario checks both exact strings; controls.json includes the counterexample treating confirmed logout as a probe error.
- Addressed: Request Acceptance 2 requires a nonzero probe to report inability to check without claiming logout. Its scenario checks failure and an unavailable-auth-status diagnosis; controls.json includes the counterexample collapsing a probe error into the logged-out message.
- Addressed: Request Acceptance 3 requires malformed JSON to be invalid or unavailable while a valid claude.ai subscription stays ready. Separate malformed and subscription scenarios check both sides; controls.json includes malformed-as-logout and valid-as-invalid counterexamples, rejecting collapsed outcomes.
- Addressed: Request Scope and Out of scope remain exact: production edits only in cli/readiness/readiness.go and cli/readiness/readiness_test.go, no changes to Claude Code version pinning, token custody or supported sign-in routes. Intent-owned helpers and overlays are verification artifacts, not additional product changes.
- Omitted: no requested behavior. Conflicting: none. Superseded: only the old classification of probe and JSON errors as absent subscription sign-in; confirmed logout and valid subscription behavior remain.

## Tests
- Confirmed logout keeps its message and fix: preserve TestClaudeChecks coverage in cli/readiness/readiness_test.go and compare the complete models diagnosis, login fix and rendered text in acceptance (integration)
- A failed auth status probe is unavailable rather than confirmed logout and keeps readiness failed: add a nonzero managed-runtime regression in cli/readiness/readiness_test.go and exercise it through the public report in acceptance (regression)
- Malformed auth status JSON is invalid or unavailable rather than confirmed logout and keeps readiness failed: add a malformed-output regression in cli/readiness/readiness_test.go and exercise it through the public report in acceptance (regression)
- Valid claude.ai subscription authentication stays ready: preserve TestClaudeChecks subscription coverage and verify the models report remains ready with no fix in acceptance (integration)

## Feasibility
- The local pinned executor exposes the existing managed-runtime test seam; the unchanged TestClaudeChecks passed. No changed external protocol or live account access is needed for this reporting fix. (probe 1: exit 0, 1.4 s)
- Inspected the installed dependency's Probe implementation to confirm that the fixture exercises the real adapter subprocess path rather than a production replacement. (probe 2: exit 0, 0.0 s)
- The final public report helper compiled and consumed all four auth fixtures on the unchanged implementation: confirmed logout and subscription were preserved, malformed output was reported as logout, and a nonzero probe with signed-in JSON was incorrectly ready. (probe 3: exit 0, 1.5 s)
- Generated bounded correct and four single-property-wrong implementation patches programmatically. (probe 4: exit 0, 0.1 s)
- Correct and wrong patches applied and compiled in scratch; the correct overlay preserved TestClaudeChecks. Actual public report outputs from these overlays supplied the observer fixtures, augmented with independent mutations for deeper assertions. (probe 5: exit 0, 3.7 s)
- evidence: {"id":"auth-report-observer","kind":"observer","inputs":[".kogen/intents/readiness-claude-auth-probe-errors/observer-fixtures.json"],"observers":["features/steps/readiness-claude-auth-probe-errors__driver/observe.cjs"],"checks":[{"name":"good","command":"node features/steps/readiness-claude-auth-probe-errors__driver/observe.cjs .kogen/intents/readiness-claude-auth-probe-errors/observer-fixtures.json good","exit":0,"output":"accepted\n"},{"name":"bad","command":"node features/steps/readiness-claude-auth-probe-errors__driver/observe.cjs .kogen/intents/readiness-claude-auth-probe-errors/observer-fixtures.json bad","exit":1,"output":"rejected\n"}]}
