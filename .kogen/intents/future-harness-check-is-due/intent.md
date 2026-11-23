# Treat a future harness check time as due

Slug: future-harness-check-is-due
Model: not applicable — Harness.due is a pure function of a timestamp string and a given now, with no state
Acceptance:
- .kogen/intents/future-harness-check-is-due/acceptance.feature
- features/steps/future-harness-check-is-due__steps.js

Harness.due in cli/internal/claudecode/update.go reports whether the daily Claude Code harness check is due. Today a checked_at timestamp later than now yields a negative elapsed time, so the check is treated as fresh and clock skew can postpone the daily check until the clock catches up. After this change a checked_at strictly later than now is due. A checked_at equal to now keeps its current result (not due, because zero elapsed time is not older than 24 hours). Only update.go and update_test.go change; update scheduling, installation, self-test behavior and every doc, design and README file stay as they are. The results for a missing, an invalid, a 23-hour-old, an exactly-24-hour-old and a 25-hour-old timestamp, and the 24-hour interval, do not change; existing tests in update_test.go protect them and they are not acceptance scenarios.

The Build adds one new test to update_test.go that sets checked_at one hour later than now, using the same mechanism as the existing TestHarnessDueAfterADay (a fixed `now` passed to `due`, no sleeping), and asserts that Harness.due returns true. Acceptance runs a throwaway equivalent test through `go test -overlay` in the one package, so it does not depend on the name of the Build's test.

## Decisions
- Harness.due takes the current time as its `now` argument and the existing test builds checked_at from a fixed now, so the new test passes a fixed now and a checked_at one hour later, with no real clock wait. (decision: D1, round 1) (evidence: cli/internal/claudecode/update.go; cli/internal/claudecode/update_test.go) (source: request)
- A timestamp is in the future only when it is strictly later than now (after the RFC 3339 parse); a future timestamp is due. A timestamp equal to now keeps its current result, not due. (decision: D2, round 1) (evidence: cli/internal/claudecode/update.go) (source: request)
- The 24-hour interval and the results for missing, invalid, 23-hour, exactly-24-hour and 25-hour timestamps do not change, and nothing outside update.go and update_test.go changes. (decision: D3, round 1) (evidence: cli/internal/claudecode/update_test.go) (source: request)
- Acceptance is one model-free `go test` run, with the ordinary build cache, of a throwaway test overlaid on the single package cli/internal/claudecode that asserts a checked_at one hour later than now is due. The wrong implementation treats a future timestamp as fresh. (decision: D4, round 1) (evidence: cli/internal/claudecode/update.go) (source: request)

## Source comparison
- Future checked_at is due: addressed by the scenario and the new update_test.go test (source: request).
- Equal-to-now keeps its current result, not due: unchanged behavior, preserved by the implementation and reviewed, not an acceptance scenario (source: request).
- Existing results for missing, invalid, 23h, 24h, 25h timestamps and the 24-hour interval: preserved, covered by the existing TestHarnessDueAfterADay (source: request).
- Update scheduling, installation, self-test behavior and doc/design/README files: out of scope, untouched (source: request).

## Tests
- A checked_at one hour later than now is due: new Harness.due test in cli/internal/claudecode/update_test.go (unit)
- Missing, invalid, 23-hour, 24-hour and 25-hour results are unchanged: TestHarnessDueAfterADay (existing)

## Feasibility
- none
