Feature: Retry or resume a verdictless green review
  The tests below use local fake providers and temporary Git checkouts.
  Each exact named regression must run and assert its complete scenario.
  No paid calls, process-name kills, synthetic load or configured limit increases are permitted.

  Scenario: Retry an invalid review once and land its green candidate
    Verification passes. Review 1 returns prose without submit_review, including
    after its own reminder; review 2 is a fresh same-kind conversation and approves.
    Assert one landed commit, unchanged green candidate material and rules, no
    builder replay to the reviewer, next review numbering, and retained log records
    identifying review 1 as invalid with its reason and review 2 as approved.
    Repeat the fault using validation-rejected verdicts rather than prose-only turns.
    When the reviewretry contract test "TestKReviewRetryFreshConversation" runs
    Then that reviewretry contract test executes once and passes

  Scenario: Resume only review after both automatic conversations fail
    Through kogen intent build, make verification green and exhaust review 1 and
    review 2 without valid verdicts. Assert candidate/review_invalid, no commit,
    preserved green tree and a durable checkpoint. Then invoke
    kogen intent resume <build-id> on that unchanged checkout; review 3 approves.
    Assert landing, fresh independent conversation, same material and rules,
    no new builder rounds, no rerun of completed green checks and retained lineage.
    Also let review 3 end invalid: it stops without an automatic review 4, because
    explicit resume did not replenish the one automatic retry for that candidate.
    When the reviewretry contract test "TestKReviewRetryReviewOnlyResume" runs
    Then that reviewretry contract test executes once and passes

  Scenario: Refuse a changed checkout without side effects
    After the two-invalid-review stop, change a candidate file and invoke the actual
    kogen intent resume <build-id> command. Assert refusal, no provider request,
    no build round or commit, and unchanged files, index, HEAD and approval relative
    to immediately before Resume. The unchanged-checkout control must resume successfully.
    When the reviewretry contract test "TestKReviewRetryChangedCheckout" runs
    Then that reviewretry contract test executes once and passes

  Scenario: Reproduce S-DECREL without replacing the conversation
    Deliver material with 232 pinned source parts. Actually reject submit_review
    for unread parts, then receive a prose-only answer, then on the reminder request
    receive a forced submit_review with a valid verdict after complete real delivery.
    Assert approval within review 1 and one conversation identity, both separate
    counters in the log and the actual unread rejection. Do not mark unread parts
    delivered merely because they were catalogued. Preserve unread-progress exemption.
    Test the reverse consumption order too. A second non-exempt rejected verdict
    exhausts only the rejected-verdict allowance; a second no-tool turn exhausts
    only the no-tool allowance. Neither allowance is raised.
    When the reviewretry contract test "TestKReviewRetrySeparateAllowances" runs
    Then that reviewretry contract test executes once and passes

  Scenario: Force only the reminder request on supported routes
    With fake transports, inspect the actual serialized reminder request requiring
    submit_review on supported routes and ordinary choice on the next request.
    For a route without supported named tool choice, assert today's reminder text,
    no unsupported forcing field, and a log record identifying text-only fallback.
    Assert forcing never bypasses source delivery or verdict validation, changes
    role/model/effort, disables thinking, or adds a provider-refusal retry.
    When the reviewretry contract test "TestKReviewRetryReminderChoice" runs
    Then that reviewretry contract test executes once and passes

  Scenario: Preserve ordinary valid review requests byte for byte
    For first-valid approve and changes verdicts, compare complete requests against
    baseline wire fixtures under fixed inputs, time and conversation identity.
    Assert byte equality, original independence/material delivery/validation, and
    today's landing or substantive-blocker outcome without automatic invalid retry.
    When the reviewretry contract test "TestKReviewRetryUnchangedValidRequests" runs
    Then that reviewretry contract test executes once and passes

  Scenario: Keep retry and checkpoint safety bounded
    Assert automatic retry consumption and separate counters survive checkpoints
    and working-window continuation. Native and external same-kind fresh reviews
    retain their delivery rules. A completed read-only review must not be refused
    solely as an uncertain tool boundary. A review that wrote the candidate, an
    incomplete mutating tool batch, a changed index or HEAD, invalid custody or
    stale green evidence must not receive this relaxation. Assert substantive
    blockers are not classified as invalid reviews and no CLI option, timeout,
    other limit or retry default has been raised.
    When the reviewretry contract test "TestKReviewRetrySafetyBoundaries" runs
    Then that reviewretry contract test executes once and passes
