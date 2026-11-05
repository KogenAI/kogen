Feature: kogen's acceptance answers Shape's decision check
  kogen-shaping 1e795ed and later (here 6a80040) give every Shape candidate a decision check
  that only one submit_decision_check call with an items list answers. These scenarios run
  scenarios of kogen's own acceptance suite (test/acceptance) against the release built from
  this checkout, and against that release with kogen rebuilt with kogen-shaping 6a80040 in a
  disposable copy (cli/go.mod is protected and stays unchanged).

  Background:
    Given k-acceptance-decision-check-answer: the release archive built from this checkout

  Scenario: Shaping scenarios pass with kogen-shaping 6a80040
    Given k-acceptance-decision-check-answer: the release's kogen is rebuilt with "github.com/KogenAI/kogen-shaping" at "v0.0.0-20261104024305-6a80040aa78b"
    When k-acceptance-decision-check-answer: kogen's acceptance suite runs these scenarios against the release:
      | feature                         | scenario                                                                              |
      | 02-shaping.feature              | A complete request from stdin becomes a ready Intent and nothing is approved          |
      | 02-shaping.feature              | Answers continue shaping and the decision records its source                          |
      | 02-shaping.feature              | A question the check does not class as UI/UX goes back to the shaper and is not asked |
      | claude-code-full-lineup.feature | Claude lineup shapes builds reviews and signs one exact-tree commit                   |
      | claude-code-full-lineup.feature | Shape questions retain numbered CLI answers and start a fresh subsequent session      |
    Then k-acceptance-decision-check-answer: every requested scenario passed
    And k-acceptance-decision-check-answer: the suite run reported no "decision_check_invalid"

  Scenario: The same shaping scenarios still pass with kogen's current pins
    When k-acceptance-decision-check-answer: kogen's acceptance suite runs these scenarios against the release:
      | feature                         | scenario                                                                              |
      | 02-shaping.feature              | A complete request from stdin becomes a ready Intent and nothing is approved          |
      | 02-shaping.feature              | Answers continue shaping and the decision records its source                          |
      | 02-shaping.feature              | A question the check does not class as UI/UX goes back to the shaper and is not asked |
      | claude-code-full-lineup.feature | Claude lineup shapes builds reviews and signs one exact-tree commit                   |
      | claude-code-full-lineup.feature | Shape questions retain numbered CLI answers and start a fresh subsequent session      |
    Then k-acceptance-decision-check-answer: every requested scenario passed

  Scenario: A decision check answer without a submit_decision_check call still stops Shape
    Given k-acceptance-decision-check-answer: the release's kogen is rebuilt with "github.com/KogenAI/kogen-shaping" at "v0.0.0-20261104024305-6a80040aa78b"
    When k-acceptance-decision-check-answer: kogen's acceptance suite runs this feature against the release:
      ```
      Feature: A decision check answer without a submit_decision_check call

        Background:
          Given a clean Kogen home
          And the installed kogen command
          And a Git project from fixture "py-calc"
          And the project is initialized and configured
          And the caller is signed in to ChatGPT

        Scenario: A scripted decision check answer with no submit_decision_check call stops Shape
          Given the fake ChatGPT server plays script "shape-decision-check-without-call"
          When the caller runs "kogen intent shape is-even -" with stdin:
            """
            Add calc.is_even(n).
            """
          Then the exit code is 1
          And stdout contains "shape/decision_check_invalid: the decision check answer is not a valid submit_decision_check payload (expected one submit_decision_check call); nothing was published"
          And stdout does not contain "Next: kogen intent approve is-even"
          And the fake ChatGPT server received 1 request
      ```
    Then k-acceptance-decision-check-answer: every requested scenario passed
