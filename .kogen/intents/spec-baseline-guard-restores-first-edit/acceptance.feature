Feature: The assembly spec states the restore of a first protected edit and the refusal of a second

  This feature reads the assembly spec and its fake ChatGPT fixtures as they are in the working tree.

  Scenario: The restore outline covers a first shell edit of each protected path
    Then spec-baseline-guard-restores-first-edit: the spec has exactly one outline containing "acceptance files cannot be edited" tagged "@VER-8 @VER-12 @model:build" with the example paths ".kogen/intents/is-even/acceptance.feature,features/steps/is_even_steps.js,.style.cfg"
    And spec-baseline-guard-restores-first-edit: that outline plays the script "build-runs-command"
    And spec-baseline-guard-restores-first-edit: that outline has the steps:
      """
      Given the Intent "is-even" from fixture "is-even" is approved
      And the fake ChatGPT server plays script "<script>" with command "<command>"
      When the caller runs "kogen intent build is-even"
      Then the tool result for the first shell call contains "<path>"
      And the tool result for the first shell call contains "acceptance files cannot be edited"
      And the file "<path>" is unchanged
      And the file ".kogen/intents/is-even/acceptance.feature" is unchanged
      And the exit code is 0
      """

  Scenario: The refusal outline covers a second shell edit of each protected path
    Then spec-baseline-guard-restores-first-edit: the spec has exactly one outline containing "candidate/baseline_changed: the Build changed acceptance files: <path>; nothing was committed" tagged "@VER-8 @VER-12 @model:build" with the example paths ".kogen/intents/is-even/acceptance.feature,features/steps/is_even_steps.js,.style.cfg"
    And spec-baseline-guard-restores-first-edit: that outline has the steps:
      """
      Given the Intent "is-even" from fixture "is-even" is approved
      And the fake ChatGPT server plays script "<script>" with command "<command>"
      When the caller runs "kogen intent build is-even"
      Then the exit code is 1
      And stdout contains "candidate/baseline_changed: the Build changed acceptance files: <path>; nothing was committed"
      And no request was sent after that command
      And HEAD is unchanged
      """
    And spec-baseline-guard-restores-first-edit: that outline plays a script that the fake ChatGPT server knows, other than the unchanged script "build-runs-command"

  Scenario: The old outline is gone
    Then spec-baseline-guard-restores-first-edit: the spec has no scenario named "Weakening the baseline is refused or stops the Build at once"

  Scenario: Every other scenario of the spec file stays as it is
    Then spec-baseline-guard-restores-first-edit: every other scenario of the spec file is unchanged from HEAD
