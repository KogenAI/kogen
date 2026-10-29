# Retry every verdictless review once

Slug: k-reviewretry2
Model: .kogen/intents/k-reviewretry2/model.qnt invariants=Budget,Spent,Stop seed=2 samples=100 steps=12
Acceptance:
- .kogen/intents/k-reviewretry2/acceptance.feature
- features/steps/k_reviewretry2_steps.js

Fix K-REVIEWRETRY-2 without a CLI change. Any first review ending without a valid verdict on a green candidate gets exactly one fresh same-kind conversation, independent of the termination reason. This includes no_tool_reminder_exhausted, rejected verdicts, window resets and other verdictless endings; do not use a reason allowlist. Keep the existing explicit review-only resume after a second failure. Never clear a substantive valid blocker by retrying it.

In review-and-fix mode, merely having or using edit tools is not ineligibility. Discard the invalid reviewer's uncommitted edits and start the fresh review from the exact green candidate tree, not HEAD's pre-build tree. Record the discarded edits in the run log. Preserve the builder's candidate, approval, protection, custody and index safety. A reviewer whose changes have been committed into the candidate remains ineligible; do not undo such commits. Do not broaden explicit resume eligibility or other safety bypasses.

After a working-context reset, the actual reminder request on a route supporting named selection must retain pinned provider.Request.ToolChoice = submit_review. Measure and send the same selection. A text-only response to an api_forced turn is a provider fault, logged with route and model, never unread_progress_exempt. It consumes the ordinary no-tool handling, not another retry allowance. Unsupported routes retain their existing fallback. No provider integration redesign or live qualification is required.

## Decisions
- Automatically start one fresh review for any verdictless end on the recoverable green candidate; retain second-failure review-only resume (source: request)
- Roll back only uncommitted invalid-reviewer edits and log them; committed reviewer changes remain ineligible (source: request)
- Preserve valid-verdict behavior byte-for-byte, CLI, all limits/timeouts/defaults, and vendored loop bytes; use pinned ToolChoice (source: request)
- Shared host safety: temp directories only; never stop by process name or pattern, only PIDs started by the test (source: request)

## Source comparison
- Addressed request Why and acceptance (a): TestKReviewRetry2LogReplay must reproduce the S-HISTSUPER Build 45d63b0d shape (studio, Terra medium, 29 Oct 2026): reset 656837 to 297809 bytes, prose, api_forced reminder, 78 output tokens without a call, verdictless no_tool_reminder_exhausted. Those sizes are historical diagnostics, not mandatory generated request sizes. Assert review 2, unlike the old review_invalid stop with no review_retry. Synthetic tests need not claim possession of the private historical log.
- Addressed fixes 1 and 4 and acceptance (a,c): generic termination coverage and real-Git candidate rollback below supersede the reason-specific/read-only eligibility behavior in cli/build/review_retry.go. Existing code is not scope authority.
- Addressed fixes 2 and 3 and acceptance (b): actual sent body and provider-fault assertions below cover the reset/reminder bug, not just a review_tool_choice log claiming api_forced.
- Addressed Must stay and All configured checks pass: existing valid-request byte comparisons and configured checks remain mandatory. README's read-only automatic eligibility description is superseded only for safely discarded uncommitted reviewer edits; its explicit resume contract is unchanged. Vendored code and cli/loop-pin.json are not implementation targets.
- Omitted: no requested behavior; historical metadata is retained as a regression description rather than an invented private log fixture.

## Tests
- Reset/prose/forced-text verdictless regression starts exactly review 2: add TestKReviewRetry2LogReplay through the existing real Build entry fixture with local scripted transport (regression)
- All verdictless reasons share the one-fresh-review gate: add TestKReviewRetry2AnyEnd, exercising an arbitrary reason outside existing names as well as rejected verdicts; second failure stops review_invalid with one automatic event, and existing explicit resume starts only one further review (integration)
- Forced choice survives reset and text-only forced response is a provider fault: add TestKReviewRetry2ForcedReset, observing the actual HTTP body after a real context reset on supporting routes, route/model fault fields and absence of unread_progress_exempt for that response (regression)
- Uncommitted review-and-fix edits are discarded, logged and never leak into review 2: add TestKReviewRetry2DiscardEdits using real temporary Git, tracked modifications/deletions and reviewer additions, preserving green candidate bytes and showing fresh conversation identity; committed reviewer edits do not trigger rollback/retry (integration)
- Valid verdicts remain byte-identical, separate existing allowances and explicit resume remain unchanged: retain TestKReviewRetryUnchangedValidRequests, TestKReviewRetrySeparateAllowances and TestKReviewRetryReviewOnlyResume, updating obsolete eligibility expectations only where this contract replaces them (existing)

The four new Go tests are implementation-owned under cli/build, not protected Acceptance inputs. Reuse newEnv, fakeProvider and existing review/Build fixtures. Assertions must check real outcomes (including exactly one review_retry, fresh cache identity, no builder replay or completed-check rerun), not private helper order. The generic reason test may additionally exercise the common gate directly, but the replay and rollback cases must traverse the real Build entry. Forced-reset tests must establish that a reset actually happened and inspect transmitted JSON, not a pre-reset request object. Do not fabricate the recorded historical byte counts as a substitute for exercising a reset. Preserve useful tests and replace obsolete mutating-tool rejection expectations.

## Feasibility
- Pinned ToolChoice and current native Request/bodyOf paths were inspected; this is local request lifecycle and Git recovery work, not a new provider capability. No paid/network probe is needed.
- Quint model typechecked successfully (probe: exit 0, 0.8 s).
- Existing valid-byte test invocation observed pass: cd cli && go test -json ./build -run '^TestKReviewRetryUnchangedValidRequests$' -count=1 (probe, final three JSON events observed; exit 0, 1.2 s).
- evidence: {"id":"named-test-observer","kind":"observer","inputs":["features/steps/k_reviewretry2_steps.js"],"observers":["features/steps/k_reviewretry2_steps.js"],"checks":[{"name":"good","command":"node features/steps/k_reviewretry2_steps.js --control good","exit":0,"output":"reviewretry2 good\n"},{"name":"bad","command":"node features/steps/k_reviewretry2_steps.js --control bad","exit":1,"output":"reviewretry2 rejected absent test\n"}]}
