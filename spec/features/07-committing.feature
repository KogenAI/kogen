Feature: Committing
  One commit of exactly the verified and reviewed contents on the same HEAD,
  following the user's own Git configuration; otherwise the edits stay uncommitted.

  Background:
    Given a clean Kogen home
    And the installed kogen command
    And a Git project from fixture "py-calc"
    And the project is initialized and configured
    And the caller is signed in to ChatGPT
    And the Intent "is-even" from fixture "is-even" is approved

  @GIT-3 @GIT-4 @GIT-5 @GIT-8 @model:build
  Scenario: A verified, approved Build makes one commit
    Given commit signing is configured with a test SSH key
    And the fake ChatGPT server plays script "build-correct-first-try"
    When the caller runs "kogen intent build is-even"
    Then the exit code is 0
    And stdout is:
      """
      building is-even
      landed is-even {sha8} (Build {id8})
        checks: acceptance 3/3, model not applicable, test passed
        review: approved, 1 note(s)
        note: calc.py:12: the docstring could name TypeError
        repairs: 0 · tokens: {n} · time: {dur}
      """
    And HEAD has 1 new commit
    And the new commit's message is:
      """
      Add an is-even helper

      Kogen-Intent: is-even
      """
    And the new commit changes exactly:
      | path                                      |
      | .kogen/intents/is-even/intent.md          |
      | .kogen/intents/is-even/acceptance.feature |
      | features/steps/is_even_steps.js           |
      | calc.py                                   |
      | tests/test_calc.py                        |
    And the new commit is signed
    And the file ".kogen/local/approvals/is-even.json" does not exist

  @GIT-5
  Scenario: Without signing configured the commit is unsigned and the Build still lands
    Given the fake ChatGPT server plays script "build-correct-first-try"
    When the caller runs "kogen intent build is-even"
    Then the exit code is 0
    And the new commit is not signed

  @GIT-1
  Scenario: Unrelated changes block the start
    Given the file "notes.txt" is created and staged
    When the caller runs "kogen intent build is-even"
    Then the exit code is 5
    And stdout is:
      """
      environment/dirty_tree: 1 changed path(s) are not part of an Intent; commit, stash or discard them first
        notes.txt
        no newly created Build run; correct the named prerequisite before trying again
      """

  @GIT-3 @model:build
  Scenario: A moved HEAD during the Build refuses the commit
    Given the fake ChatGPT server plays script "build-correct-first-try" pausing at "finish"
    And the caller runs "kogen intent build is-even" in the background
    And the fake ChatGPT server reaches "finish"
    And another commit is made on HEAD
    When the fake ChatGPT server continues
    And the background command finishes
    Then the exit code is 1
    And stdout contains "candidate/head_moved: HEAD moved from "
    And HEAD has no commit by Kogen

  @GIT-5
  Scenario: A failing git commit leaves the verified changes uncommitted
    Given commit signing is configured with a missing key
    And the fake ChatGPT server plays script "build-correct-first-try"
    When the caller runs "kogen intent build is-even"
    Then the exit code is 3
    And stdout contains "environment/commit_failed: git commit failed (status "
    And HEAD is unchanged
    And nothing is staged

  @GIT-6 @model:build
  Scenario: A commit hook that changes what is committed gets the commit undone and off the branch
    Given a pre-commit hook that appends a line to "calc.py" and stages it
    And the fake ChatGPT server plays script "build-correct-first-try"
    When the caller runs "kogen intent build is-even"
    Then the exit code is 1
    And stdout contains "candidate/hook_changed_commit: a commit hook changed calc.py; the commit was undone and the changes are left in place"
    And HEAD is unchanged
    And the path "calc.py" has uncommitted changes

  @GIT-7
  Scenario: Kogen runs no Git command that rewrites or shares history
    Given the fake ChatGPT server plays script "build-correct-first-try"
    When the caller runs "kogen intent build is-even"
    Then no Kogen git invocation used push, fetch, rebase, merge, cherry-pick, reset, stash, switch, checkout or commit --amend
    And no Kogen git invocation disabled signing or hooks
