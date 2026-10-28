Feature: Internal Shape submission retry budget
  Scenario Outline: Execute the retry contract through real entry points
    When the submission retry integration test "<test>" runs
    Then that submission retry test passed without skipping

    Examples:
      | test                          |
      | TestSubmissionRetryDefault    |
      | TestSubmissionRetryOne        |
      | TestSubmissionRetryFive       |
      | TestSubmissionRetryRefine     |
      | TestSubmissionRetryExternal   |
      | TestSubmissionRetryEvidence   |
