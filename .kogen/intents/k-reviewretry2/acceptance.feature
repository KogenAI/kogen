Feature: One fresh review after any verdictless end
  Scenario Outline: Real review retry regressions and preserved behavior
    When reviewretry2 Go test "<test>" runs
    Then reviewretry2 test "<test>" ran once and passed
    Examples:
      | test |
      | TestKReviewRetry2LogReplay |
      | TestKReviewRetry2AnyEnd |
      | TestKReviewRetry2ForcedReset |
      | TestKReviewRetry2DiscardEdits |
      | TestKReviewRetryUnchangedValidRequests |
      | TestKReviewRetrySeparateAllowances |
      | TestKReviewRetryReviewOnlyResume |
