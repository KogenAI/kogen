Feature: Restore complete oversized pinned review delivery

  Background:
    Given a clean Kogen home
    And the installed kogen command
    And a Git project from fixture "py-calc"
    And the project is initialized and configured
    And the caller is signed in to ChatGPT
    And the Intent "is-even" from fixture "is-even" is approved

  Scenario: Oversized initial source remains complete and must reach the independent reviewer before approval
    Given the fake ChatGPT server plays script "build-large-review-evidence"
    When the caller runs "kogen intent build is-even"
    Then the exit code is 0
    And the review request retains bounded complete pinned source evidence
    And the review request does not contain the builder's conversation, tool calls or tool results
    And no builder request was sent after review began
    And the Build records 1 review stage and 1 verification pass
    And HEAD has 1 new commit

  Scenario: Altered pinned review source refuses before another tool or approval
    Given the fake ChatGPT server plays script "build-large-review-evidence-drift"
    When the caller runs "kogen intent build is-even"
    Then the exit code is 1
    And stdout contains "candidate/resume_refused"
    And stdout contains "working-context history custody missing, changed or unsafe"
    And HEAD is unchanged
