# Reject changes verdicts while parts are unread

Slug: k11-review-unread-parts
Model: not applicable — one extra verdict-validation rule and a retry-limit exemption in an existing loop; no new state machine
Acceptance:
- .kogen/intents/k11-review-unread-parts/acceptance.feature
- features/steps/k11_review_unread_steps.js
- features/steps/k11_review_unread_driver.go

A native Build once ended `candidate/review_blocked` because Kogen's own prefill delivered only part of a large pinned review source and the reviewer, having read none of the rest, answered `changes` with a single blocking finding that the remaining parts were not delivered. The unread-part gate in `reviewRun.validate` (cli/build/review.go) applies only to `approve`, so this incomplete delivery was treated as a real blocker.

Change `reviewRun.validate` so that, for a native (non-external) review, a `changes` verdict is also rejected while pinned source parts are unread (same `b.materialUnread(input)` check as approve). The problem text is exactly `<N> pinned part(s) unread; read them before a verdict; incomplete delivery is not a candidate defect; use read_file on <p1>, <p2>, ...`, naming at most the first 8 unread parts exactly as the approve message does (same ordering). It reaches the reviewer as the usual `invalid verdict:\n...` submit_review tool output. Other problems found in the same call are still listed alongside it.

Change `reviewRun.converse`: a verdict whose problems include this unread-parts problem does not count toward the one-invalid-verdict limit while the unread count is lower than the unread count of the previous answer carrying this problem. The first such answer has no predecessor and is not counted either (it is the baseline); a later one whose unread count is equal to or greater than the previous one counts as an ordinary invalid answer, so a reviewer that never reads is still stopped by the existing limit (`candidate/review_invalid`) or, once nothing is unread, by its real `changes` verdict (`candidate/review_blocked`). Any other invalid problem counts as before.

K1 re-review follow-ups:
- cli/build/review_external.go: the `b.facts.update(b, "reviewing", "")` call returns its error: `if err := b.facts.update(b, "reviewing", ""); err != nil { return Approved{}, err }`.
- cli/build/review_lineup_test.go, subtest "native builder checkpoint" of `TestClaudeLineupReviewRefusesResume`: also assert the resume result (exit 0) and that the candidate landed.
- cli/shape/external_test.go (or another test file in cli/shape): add `TestSumUsagePartialWhenStatesDiffer`, a unit test of `sumUsage` showing that when both rounds report a cost but their usage states differ, the total state is `executor.UsagePartial` (and the costs are summed). Production `sumUsage` already has this semantics and is not changed.

Unchanged: approve behaviour and its message; a `changes` verdict after all parts were read with a real blocking finding still ends `candidate/review_blocked`; the external reviewer path (`r.external`), resume's `selectReviewer` call, review prompts, the findings schema, and every other validation rule. Out of scope: prefill size, chunking, image budget, findings-as-string repair, provider code.

## Decisions
- Reuse the approve check for `changes`, skipped for external reviewers as for approve. (source: request)
- Problem text is fixed as above so it is checkable; it names parts like the approve message. (source: request)
- The unread count is compared with the previous answer carrying this problem; a non-falling count falls back to the existing one-invalid limit. (source: request)
- `sumUsage` test lives in package cli/shape because `sumUsage` is defined in cli/shape/external.go. (source: request)

## Source comparison
- addressed: validate gate for `changes` with the specified text, in acceptance scenarios 1-3 and a native unit test.
- addressed: converse limit exemption while the count falls, non-falling still limited, in scenarios 2 and 4 plus native tests.
- addressed: real `changes` after all parts read still `review_blocked` (scenario 3); approve behaviour unchanged (existing tests).
- addressed: review_external.go error return, resume subtest assertions, sumUsage unit test (scenario 5).
- omitted deliberately: prefill size, chunking, KOGEN-062 image budget, findings-as-string repair, provider code (request out of scope).
- clarified: the request located sumUsage ambiguously; it is in cli/shape/external.go, so the test goes there.
- correction (observer only): k11_review_unread_driver.go now collects unread-parts feedback (function_call_output items answering a submit_review call in the same request) across ALL review requests, de-duplicated by call_id, because working-window resets archive older exchanges before the last request. Every other assertion, the Intent behaviour and working-window reset behaviour are unchanged.

## Tests
- `changes` with unread pinned parts gets the unread problem and the reviewer keeps reading, then lands: add a test in cli/build/review_test.go using the fake reviewer (integration)
- unread problem not counted while the count falls; counted when it does not fall: tests in cli/build/review_test.go, the latter with a fake reviewer whose unread count does not fall (integration)
- `changes` with a real blocking finding after all parts read stays `review_blocked`: test or existing coverage (regression)
- approve with unread parts keeps the existing feedback: TestApprovalNeedsEveryPinnedPartDeliveredInACompletedContinuation (existing)
- review_external.go returns the facts.update error: covered by the acceptance source check (existing)
- resume subtest asserts exit 0 and landed: update TestClaudeLineupReviewRefusesResume (integration)
- sumUsage partial state with differing states and costs: TestSumUsagePartialWhenStatesDiffer (unit)

## Feasibility
- A scratch overlay run of the driver against the unchanged tree reproduces the defect: `changes` with unread parts ends `review_blocked` after one request with no unread feedback; a read-everything-then-`changes` reviewer ends `review_blocked` after 9 requests. (probe 1: exit 0, 5 s)
- evidence: {"id":"k11-observer","kind":"observer","inputs":["features/steps/k11_review_unread_steps.js","features/steps/k11_review_unread_driver.go"],"observers":["features/steps/k11_review_unread_steps.js","features/steps/k11_review_unread_driver.go"],"checks":[{"name":"good","command":"\"$KOGEN_NODE\" features/steps/k11_review_unread_steps.js --control good","exit":0,"output":"k11 observer good\n"},{"name":"bad","command":"\"$KOGEN_NODE\" features/steps/k11_review_unread_steps.js --control bad","exit":1,"output":"k11 observer rejected bad fixtures\n"}]}
