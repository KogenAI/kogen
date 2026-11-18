# Accept the optional Route line in provider list

Slug: spec-provider-list-names-messages-route
Model: not applicable — the change edits static scenario text and has no meaningful runtime state
Acceptance:
- .kogen/intents/spec-provider-list-names-messages-route/acceptance.feature
- features/steps/spec-provider-list-names-messages-route__steps.js

The release acceptance suite fails four scenarios of `spec/features/08-chatgpt.feature` because `kogen provider list` now prints one extra line between the `Recommended ChatGPT defaults:` line and the `Other model/effort/role strings` sentence (`OfficialText` in provider/profiles.go of the new component prints it), while the specification still expects the old output. The vendored producer of this repository still prints the old output until the release adopts the new component heads, so the assertions must pass both with and without that one line and fail on any other difference.

The optional Route line is exactly: `Route messages-compatible (experimental): an explicit streamed Messages wire sent only to the role's base_url; no profile qualifies it, so every model on it is experimental. Local fixtures only; live qualification and account debit reconciliation are still required.`

The four scenarios are "Browser login, private credentials and the status command" (two `kogen provider list` runs), "An incomplete saved login is not reported as signed in" (one run), "SuperGrok status is local and requires Kogen-owned credentials" (two runs) and "Saved native Claude keys are local status rather than verified API access" (one run). In each `kogen provider list` run, replace the exact `stdout is:` block by one existing `stdout matches "..."` step: an anchored regular expression (`^` ... `$`) over the whole output, every other line kept exactly and in order (escaped literally, joined by `\n`), with the Route line plus its newline as an optional group between the `Recommended ChatGPT defaults:` line and the `Other model/effort/role strings` sentence. The first lines (the sign-in state per provider) stay asserted as they are. No scenario is removed, skipped or tagged away, other `stdout is:` blocks stay as they are, and `cli/go.mod`, `cli/go.sum`, `cli/loop-pin.json`, the vendored component trees, `.kogen/project.yaml`, checks and protections are not edited. This follows the precedent of commit eab9297b.

The builder must run the whole 08-chatgpt feature through the maintained acceptance suite and report the exact commands and results.

## Decisions
- Use the existing `stdout matches` step with an anchored whole-output regular expression and an optional Route-line group, with no new step vocabulary or production change. (constraint: every other line is asserted exactly and in order) (constraint: no other file than spec/features/08-chatgpt.feature changes outside the Intent) (evidence: spec/features/08-chatgpt.feature; test/acceptance/support/handlers.js) (assumption: the harness passes backslashes of a `{string}` argument through unchanged, observed only in a scratch replay of the same semantics, not in the full release suite) (source: request)
- Acceptance replays each scenario's stdout assertions through an independent harness against the old output, the new output and altered outputs, because the vendored producer still prints the old output. (evidence: spec/features/08-chatgpt.feature) (source: request)
- controls.json is deferred: the correct implementation is a six-block edit of a 21 KB feature file that the Build writes. (assumption: The request is silent on controls.json, and the line carries no evidence or assumption marker.) (source: request)
- Use the existing stdout matches step with an anchored whole-output regular expression and an optional Route-line group in the four scenarios (decision: D1, round 1) (constraint: every other line asserted exactly and in order) (constraint: no protected path edited) (evidence: spec/features/08-chatgpt.feature; test/acceptance/support/handlers.js) (assumption: Backslash passthrough in the string argument was observed only in a scratch replay of the same semantics, not in the full release suite.) (source: request)
- Acceptance replays the scenario stdout assertions against old, new and altered outputs through an independent harness (decision: D2, round 1) (evidence: spec/features/08-chatgpt.feature) (source: request)
- controls.json is deferred (decision: D3, round 1) (assumption: A scratch run showed the correct overlay passes and the exact-old, require-Route and contains-only variants fail the matching scenarios.) (source: request)

## Source comparison
- Request item 1 (assertions pass with and without the Route line, all other lines exact): addressed in the four named scenarios of spec/features/08-chatgpt.feature.
- Request item 2 (nothing else changes, first lines stay asserted): addressed by the replay rejecting a changed first or status line and by the scope scenario.
- Request item 3 (no edits to pins, vendored trees, project.yaml, checks, protections): the scope scenario rejects them.
- `OfficialText` (the component function that prints the Route line): named for context only; no production edit.

## Tests
- Output without the Route line is accepted: first scenario of acceptance.feature (scenario)
- Output with the Route line is accepted: second scenario of acceptance.feature (scenario)
- Any other difference (other line between, changed compatibility, status, first or final line) is rejected: third scenario of acceptance.feature (scenario)
- No scenario removed or skipped, no protected path edited: fourth scenario of acceptance.feature (scenario)
- The whole 08-chatgpt feature passes in the maintained suite: the configured acceptance run (existing)

## Feasibility
- none
