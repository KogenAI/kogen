Feature: Restore shaping and review acceptance
  Background:
    Given a clean Kogen home
    And the installed kogen command
    And a Git project from fixture "py-calc"
    And the project is initialized and configured
    And the caller is signed in to ChatGPT

  Scenario: Declared local rejection cannot be waived by unchanged product-red acknowledgment
    Given the fake ChatGPT server plays script "shape-declared-rejection"
    When the caller runs "kogen intent shape is-even -" with stdin:
      """
      Add the existing is-even request and qualify the declared local route control.
      """
    Then the exit code is 0
    And request 2 contains "local-route/support"
    And request 3 contains "local-route/support"
    And request 4 contains "Readiness observations"
    And the fake ChatGPT server received 4 requests
    And the file ".kogen/local/readiness/is-even.json" contains "feasibility"
    And the file ".kogen/local/readiness/is-even.json" contains "explicit rejection"
    When the caller runs "kogen intent approve is-even"
    Then the exit code is 5
    And stdout contains "Readiness observations"

  Scenario Outline: An undefined step goes back to the shaper even after an assertion failed
    Given the fake ChatGPT server plays script "<script>"
    When the caller runs "kogen intent shape is-even -" with stdin:
      """
      Add calc.is_even(n).
      """
    Then the exit code is 1
    And the fake ChatGPT server received 3 requests
    And stdout contains "intent/not_ready: the Intent is not ready to build"
    And stdout contains "  acceptance.feature line <line>: undefined step: When the caller doubles 4"
    And the file ".kogen/intents/is-even/acceptance.feature" exists
    When the caller runs "kogen intent approve is-even"
    Then the exit code is 1
    And stdout contains "intent/not_ready: the Intent is not ready to build"
    And the file ".kogen/local/approvals/is-even.json" does not exist
    Examples:
      | script                         | line |
      | shape-undefined-step           | 12   |
      | shape-failed-and-undefined-step | 14   |

  Scenario: After a not-ready attempt the shaper may ask a question; the files of that attempt stay
    Given the fake ChatGPT server plays script "shape-not-ready-then-asks"
    When the caller runs "kogen intent shape is-even -" with stdin:
      """
      Add calc.is_even(n).
      """
    Then the exit code is 5
    And stdout contains "Questions for is-even:"
    And the file ".kogen/intents/is-even/acceptance.feature" exists
    And the file ".kogen/local/approvals/is-even.json" does not exist

  Scenario: A feasibility probe runs in a scratch copy, its result is recorded, and the project stays untouched
    Given the fake ChatGPT server plays script "shape-probes-then-writes"
    When the caller runs "kogen intent shape is-even -" with stdin:
      """
      Add calc.is_even(n). Non-integers raise TypeError.
      """
    Then the exit code is 0
    And the tool result for "probe python3 -c 'print(1.5 % 2)'" contains "1.5"
    And request 1 contains "mise trust"
    And the probe ran outside the project folder
    And the file ".kogen/intents/is-even/intent.md" contains "## Feasibility"
    And the file ".kogen/intents/is-even/intent.md" contains "(probe 1: exit 0"
    And the working tree has no changes outside the Intent's files
    And no probe scratch folder is left behind

  Scenario: Oversized initial source remains complete and must reach the independent reviewer before approval
    Given the Intent "is-even" from fixture "is-even" is approved
    And the fake ChatGPT server plays script "build-large-review-evidence"
    When the caller runs "kogen intent build is-even"
    Then the exit code is 0
    And the review request retains bounded complete pinned source evidence
    And the review request does not contain the builder's conversation, tool calls or tool results
    And no builder request was sent after review began
    And the Build records 1 review stage and 1 verification pass
    And HEAD has 1 new commit
