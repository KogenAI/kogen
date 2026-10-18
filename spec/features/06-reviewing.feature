Feature: Reviewing
  After a green pass, a reviewer model reviews the code: the Intent, the full
  diff and changed files, and the check results, without the builder's
  conversation. Its review blocks the commit until it approves.

  Background:
    Given a clean Kogen home
    And the installed kogen command
    And a Git project from fixture "py-calc"
    And the project is initialized and configured
    And the caller is signed in to ChatGPT
    And the Intent "is-even" from fixture "is-even" is approved

  @REV-1 @REV-2 @REV-3 @REV-4 @model:build
  Scenario: The reviewer gets the Intent, the code and the check results, not the builder's conversation
    Given the fake ChatGPT server plays script "build-correct-first-try"
    When the caller runs "kogen intent build is-even"
    Then the exit code is 0
    And the review request uses model "gpt-6.1-sol" with effort "high"
    And the review request offers exactly the tools "read_file, list_files, search_text, submit_review"
    And the review request contains the text of the file ".kogen/intents/is-even/intent.md"
    And the review request contains the diff of "calc.py" against the start HEAD
    And the review request contains the full text of the committed "calc.py"
    And the review request contains "acceptance: passed (3 scenarios)"
    And the review request contains "nothing the Intent did not ask for"
    And the review request contains "no test is needlessly duplicated"
    And the review request does not contain the builder's plan, tool calls or tool results

  @REV-1 @model:build
  Scenario: No review while verification is red
    Given the fake ChatGPT server plays script "build-wrong-forever"
    And the caller runs "kogen intent build is-even" in the background
    When the fake ChatGPT server has sent the feedback of verification pass 3
    And the caller sends SIGINT to the kogen command
    Then no review request was sent

  @REV-4 @REV-5 @model:build
  Scenario: Blocking findings go back to the builder; the repaired code is verified and reviewed again
    Given the fake ChatGPT server plays script "build-review-changes-then-fixed"
    When the caller runs "kogen intent build is-even"
    Then the exit code is 0
    And the request after review 1 contains "review: calc.py:3: is_even accepts floats; the Intent says non-integers raise TypeError"
    And the run log shows verification pass 2 before review 2
    And stdout contains "review: approved"

  @REV-4
  Scenario: Unrequested scope is a blocking finding
    Given the fake ChatGPT server plays script "build-adds-unrequested-option-then-removes-it"
    When the caller runs "kogen intent build is-even"
    Then the exit code is 0
    And the request after review 1 contains "not asked for by the Intent"
    And the new commit does not change "calc_config.py"

  @REV-4 @model:build
  Scenario: Two invalid verdicts end the Build without a commit
    Given the fake ChatGPT server plays script "build-review-invalid-twice"
    When the caller runs "kogen intent build is-even"
    Then the exit code is 1
    And stdout contains "candidate/review_invalid: the reviewer did not return a valid verdict; edits are left in place"
    And HEAD is unchanged

  @REV-5 @REV-7
  Scenario: Notes never block and are printed and saved
    Given the fake ChatGPT server plays script "build-correct-first-try"
    When the caller runs "kogen intent build is-even"
    Then stdout contains "  review: approved, 1 note(s)"
    And stdout contains "  note: calc.py:12: the docstring could name TypeError"
    And the file ".kogen/local/runs/{build_id}/review-1.json" contains "approve"

  @REV-6 @VER-8 @model:build
  Scenario: A finding that asks to change the approved assertions cannot be satisfied in the Build
    Given the fake ChatGPT server plays script "build-review-demands-baseline-change"
    And the caller runs "kogen intent build is-even" in the background
    When the fake ChatGPT server has sent the result of the builder's write_file on the acceptance feature
    Then the tool result for "write_file .kogen/intents/is-even/acceptance.feature" starts with "refused: "
    When the caller sends SIGINT to the kogen command
    Then the file ".kogen/intents/is-even/acceptance.feature" is unchanged
    And HEAD is unchanged

  @REV-2 @REV-4
  Scenario: A finding may name an unchanged file, such as an obsolete implementation left behind
    Given the fake ChatGPT server plays script "build-leaves-old-helper-then-removes-it"
    When the caller runs "kogen intent build is-even"
    Then the exit code is 0
    And the review request 1 used read_file on "legacy_parity.py"
    And the request after review 1 contains "review: legacy_parity.py:1: obsolete parity helper; remove it"
    And the new commit changes "legacy_parity.py"
