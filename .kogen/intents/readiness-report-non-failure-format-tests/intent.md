# Test readiness report formatting for every status

Slug: readiness-report-non-failure-format-tests
Model: not applicable — the change adds Go tests for a pure string formatter; there is no state
Acceptance:
- .kogen/intents/readiness-report-non-failure-format-tests/acceptance.feature
- features/steps/readiness-report-non-failure-format-tests__steps.js

This change only extends `cli/readiness/readiness_test.go`. `Text` prints one line for every check and adds a `fix:` line only when the status is exactly `fail`. The existing mixed-status test `TestText` (a `fail` check and an `ok` check) passes on the current tree and stays as it is: it is the only test that stands for unchanged formatting. Two new tests add coverage and make no unchanged-behaviour claim of their own: one asserts that `Text(nil)` returns an empty string, the other asserts that a check whose status is neither `fail` nor `ok` prints its check line and no fix line. Nothing is replaced or removed. The formatting code, the readiness checks, the report wording and all other production code are not touched.

## Decisions
- The change touches `cli/readiness/readiness_test.go` only; `cli/readiness/readiness.go` and every other production file stay unchanged. (constraint: no other tracked file changes besides the Intent files) (evidence: cli/readiness/readiness.go; cli/readiness/readiness_test.go) (source: request)
- The existing `TestText` is kept unchanged and still asserts that a failure includes its fix line and an `ok` check does not. (constraint: `TestText` keeps its name and its exact assertion) (evidence: cli/readiness/readiness_test.go) (source: request)
- The two new tests are acceptance-checked by behaviour, not by name: the acceptance runs the package tests against `Text` variants injected with `go test -overlay` (a header or stray newline for no checks; a fix line for every status other than `ok`) and requires the package tests to fail, so the Build is free to name its tests. (constraint: acceptance names no test the Build has to invent) (evidence: cli/readiness/readiness.go; cli/readiness/readiness_test.go) (assumption: the non-failure status the new test uses is any status other than `fail` and `ok`, for example `warn`; the request does not name one) (source: request)
- Only cli/readiness/readiness_test.go changes; production code stays untouched. (decision: D1, round 1) (constraint: no other tracked file changes besides the Intent files) (evidence: cli/readiness/readiness.go; cli/readiness/readiness_test.go) (source: request)
- Existing TestText is kept unchanged as the only unchanged-formatting claim. (decision: D2, round 1) (constraint: TestText keeps its name and exact assertion) (evidence: cli/readiness/readiness_test.go) (source: request)
- New tests are acceptance-checked by injecting wrong Text variants with go test -overlay and requiring package tests to fail, not by test names. (decision: D3, round 1) (constraint: acceptance names no test the Build has to invent) (evidence: cli/readiness/readiness.go; cli/readiness/readiness_test.go) (assumption: The non-failure status the new test uses is any status other than fail and ok; the request does not name one. A scratch run in a copy showed the steps pass with the correct patch and are rejected by each wrong overlay.) (source: request)
- Only cli/readiness/readiness_test.go changes; production code stays untouched. Not an acceptance scenario; the final-tree review checks it. (decision: D4, round 1) (constraint: no other tracked file changes besides the Intent files) (evidence: cli/readiness/readiness.go; cli/readiness/readiness_test.go) (source: request)
- New tests are acceptance-checked by injecting wrong Text variants with go test -overlay and requiring package tests to fail, not by test names. (decision: D5, round 1) (constraint: acceptance names no test the Build has to invent) (evidence: cli/readiness/readiness.go; cli/readiness/readiness_test.go) (assumption: The non-failure status the new test uses is any status other than fail and ok; the request does not name one.) (source: request)

## Source comparison
- Request scenario 1, `Text(nil)` returns an empty string: addressed by the scenario "An empty report prints nothing".
- Request scenario 2, a non-failure status prints its check line and no fix line: addressed by the scenario "A non-failure status prints no fix line".
- Request scenario 3, the existing mixed-status test keeps asserting the failure-only fix rule: addressed by the scenario "The mixed-status test keeps asserting the failure-only fix rule".
- Request scope, `cli/readiness/readiness_test.go` only, production code out of scope: addressed by Decision D1; the final-tree review checks it, no acceptance scenario does.

## Tests
- `Text(nil)` returns an empty string: a new Go test in `cli/readiness/readiness_test.go` (unit)
- A check with a status other than `fail` and `ok` prints its check line and no fix line: a new Go test in `cli/readiness/readiness_test.go` (unit)
- Only failures get a fix line in a mixed report: the existing `TestText` (existing)

## Feasibility
- none
