Feature: Approval and starting a Build
  The caller approves exact bytes; only kogen intent build starts a Build;
  one Build per repository.

  Background:
    Given a clean Kogen home
    And the installed kogen command
    And a Git project from fixture "py-calc"
    And the project is initialized and configured
    And the caller is signed in to ChatGPT

  @AUT-1 @VER-2
  Scenario: The review card shows the Intent, its scenarios and its files
    Given the Intent "is-even" from fixture "is-even" is shaped
    When the caller runs "kogen intent approve is-even"
    Then the exit code is 5
    And stdout contains:
      """
      Intent: is-even — Add an is-even helper
      SHA-256: {sha256}
      Approver: {ident}

      Acceptance
        - Even numbers (fails now)
        - Odd numbers (fails now)
        - Non-integers (fails now)
      """
    And stdout contains "Readiness observations"
    And stdout contains "Checked baseline: {sha256}"
    And stdout contains "Acceptance exit: 1"
    And stdout contains "Scenario: Even numbers (acceptance.feature line 3)"
    And stdout contains "acceptance.feature line 6: Then result is True"
    And stdout contains "ImportError: cannot import name"
    And stdout contains:
      """
      Files
        - .kogen/intents/is-even/intent.md
        - .kogen/intents/is-even/acceptance.feature
        - features/steps/is_even_steps.js
        - .kogen/project.yaml
        - .style.cfg
      Approve with:
        kogen intent approve is-even {sha256}
      """

  @AUT-1
  Scenario: Approval needs a Git identity or --by
    Given the Intent "is-even" from fixture "is-even" is shaped
    And git user.name and user.email are not set
    When the caller runs "kogen intent approve is-even"
    Then the exit code is 2
    And stdout is:
      """
      intent/approval_identity_unavailable: no Git identity names the approver; run git config user.name "<name>" and git config user.email "<email>" (global or repository), or run kogen intent approve <slug> <sha> --by <name>
      """
    When the caller runs "kogen intent approve is-even --by Dana"
    Then the exit code is 5
    And stdout contains "Approver: Dana"

  @AUT-1 @VER-2
  Scenario: The review card lists a Scenario Outline once with its example count
    Given the Intent "is-even" from fixture "is-even-outline" is shaped
    When the caller runs "kogen intent approve is-even"
    Then the exit code is 5
    And stdout contains "  - Result for <kind> values (3 examples) (fails now)"
    And stdout does not contain "  - Result for even values"

  @AUT-1
  Scenario Outline: Approval refusals
    Given <condition>
    When the caller runs "<command>"
    Then the exit code is <exit>
    And stdout contains "<line>"

    Examples:
      | condition                                             | command                                    | exit | line                                                                       |
      | the Intent "is-even" from fixture "is-even" is shaped | kogen intent approve nope                  | 2    | intent/not_found: Intent does not exist                                    |
      | the Intent "is-even" from fixture "is-even" is shaped | kogen intent approve is-even 000000        | 1    | intent/hash_mismatch: is-even is now                                       |
      | the Intent "is-even" from fixture "is-even" is shaped | kogen intent approve is-even XYZ           | 2    | kogen intent approve: <hash> must be 6 to 64 lowercase hex characters      |

  @AUT-2 @model:shaping
  Scenario: Approving with the card's hash records the approval and starts nothing
    Given the Intent "is-even" from fixture "is-even" is shaped
    When the caller approves "is-even" with the hash from its review card
    Then the exit code is 0
    And stdout is:
      """
      approved is-even {sha8}
      Next: kogen intent build is-even
      """
    And the file ".kogen/local/approvals/is-even.json" exists
    And the fake ChatGPT server received 0 requests

  @AUT-2
  Scenario: Card and hash approval reuse complete readiness for the same clean candidate tree, baseline hash and HEAD
    Given readiness setup records executions outside the checkout
    And the Intent "is-even" from fixture "is-even" is shaped
    When the caller noted the review card hash of "is-even"
    And the caller approves "is-even" with the noted hash
    Then the exit code is 0
    And readiness has executed 1 time
    And the file ".kogen/local/readiness/is-even.json" exists

  @AUT-2
  Scenario: A new HEAD makes approval rerun readiness
    Given readiness setup records executions outside the checkout
    And the Intent "is-even" from fixture "is-even" is shaped
    When the caller noted the review card hash of "is-even"
    And another commit is made on HEAD
    And the caller approves "is-even" with the noted hash
    Then the exit code is 0
    And readiness has executed 2 times

  @AUT-2
  Scenario: A new baseline hash makes approval rerun readiness
    Given readiness setup records executions outside the checkout
    And the Intent "is-even" from fixture "is-even" is shaped
    When the caller noted the review card hash of "is-even"
    And the file ".kogen/intents/is-even/acceptance.feature" is changed outside Kogen
    And the caller approves "is-even" with the hash of its acceptance baseline
    Then the exit code is 0
    And readiness has executed 2 times

  @AUT-2 @VER-1
  Scenario Outline: The hash covers every baseline file
    Given the Intent "is-even" from fixture "is-even" is shaped
    And the caller noted the review card hash of "is-even"
    And the file "<path>" is changed outside Kogen
    When the caller approves "is-even" with the noted hash
    Then the exit code is 1
    And stdout contains "intent/hash_mismatch: "

    Examples:
      | path                                      |
      | .kogen/intents/is-even/acceptance.feature |
      | features/steps/is_even_steps.js           |
      | .kogen/project.yaml                       |
      | .style.cfg                                |

  @AUT-1 @AUT-2 @model:shaping
  Scenario: A not-ready Intent has no card and cannot be approved
    Given the Intent "is-even" from fixture "is-even-undefined-step" is shaped
    When the caller runs "kogen intent approve is-even"
    Then the exit code is 1
    And stdout contains "intent/not_ready: the Intent is not ready to build"
    And stdout does not contain "Approve with:"
    When the caller approves "is-even" with the hash of its acceptance baseline
    Then the exit code is 1
    And stdout contains "intent/not_ready: the Intent is not ready to build"
    And the file ".kogen/local/approvals/is-even.json" does not exist

  @AUT-3 @model:shaping
  Scenario Outline: Only a current approval can be built
    Given <condition>
    When the caller runs "kogen intent build is-even"
    Then the exit code is <exit>
    And stdout contains "<line>"
    And the fake ChatGPT server received 0 requests

    Examples:
      | condition                                                                 | exit | line                                                                       |
      | the Intent "is-even" from fixture "is-even" is shaped                     | 5    | intent/not_approved: is-even is not approved; review it with kogen intent approve is-even |
      | the Intent "is-even" from fixture "is-even" is approved and then edited   | 1    | intent/changed_since_approval: is-even changed after approval and is now   |
      | no Intent named is-even exists                                            | 2    | intent/not_found: Intent does not exist                                    |
      | the Intent "is-even" from fixture "is-even" has landed                    | 5    | intent/not_approved: is-even is not approved                               |

  @AUT-4 @model:run_control
  Scenario: A second Build in the same repository is refused while the first runs
    Given the Intent "is-even" from fixture "is-even" is approved
    And the fake ChatGPT server plays script "build-runs-command" with command "sleep 600"
    And the caller runs "kogen intent build is-even" in the background
    And the Build reaches "tool command running"
    When the caller runs "kogen intent build is-even"
    Then the exit code is 3
    And stdout contains "environment/build_running: a Build is running in this repository (pid "

  @AUT-4 @model:run_control
  Scenario: A killed Build leaves no lock behind and the next Build proceeds without a notice
    Given the Intent "is-even" from fixture "is-even" is approved
    And the fake ChatGPT server plays script "build-runs-command" with command "sleep 600"
    And the caller runs "kogen intent build is-even" in the background
    And the Build reaches "tool command running"
    When the caller sends SIGKILL to the kogen command
    And the fake ChatGPT server plays script "build-correct-first-try"
    And the caller runs "kogen intent build is-even"
    Then the exit code is 0
    And stderr does not contain "removed the lock"
    And stdout does not contain "build_running"

  @AUT-4 @model:run_control
  Scenario: The lock an earlier Kogen left for a Build that is no longer running is removed
    Given the Intent "is-even" from fixture "is-even" is approved
    And the project has a build lock of a process that is not running
    And the fake ChatGPT server plays script "build-correct-first-try"
    When the caller runs "kogen intent build is-even"
    Then the exit code is 0
    And stderr contains "kogen: removed the lock of a Build that is no longer running"

  @AUT-5
  Scenario Outline: Start checks refuse before any model request and change nothing
    Given the Intent "is-even" from fixture "is-even" is approved
    And <condition>
    When the caller runs "kogen intent build is-even"
    Then the exit code is <exit>
    And stdout contains "<line>"
    And the fake ChatGPT server received 0 requests
    And HEAD is unchanged

    Examples:
      | condition                                             | exit | line                                                                  |
      | a merge is in progress                                | 3    | environment/git_operation_in_progress: a merge is in progress         |
      | the caller is signed out of ChatGPT                   | 4    | provider/login: not signed in; run kogen provider login chatgpt       |
      | a commit-msg hook that rejects every message          | 3    | environment/commit_rejected: the commit-msg hook rejects this Intent's commit message (status=1) |

  @AUT-5
  Scenario: A failing setup stops the Build before any model request and leaves its edits
    Given the project config sets "commands.setup" to "['if [ -e .kogen/local/fail-setup ]; then echo made > setup-output.txt; false; fi']"
    And the Intent "is-even" from fixture "is-even" is approved
    And the file ".kogen/local/fail-setup" is changed outside Kogen
    When the caller runs "kogen intent build is-even"
    Then the exit code is 3
    And stdout contains "environment/setup_failed: Setup setup-1 failed (status=1)."
    And the fake ChatGPT server received 0 requests
    And the file "setup-output.txt" exists
    And HEAD is unchanged

  @AUT-5 @VER-8
  Scenario: A setup that changes the approved baseline stops the Build before the builder starts
    Given the project config sets "commands.setup" to "['if [ -e .kogen/local/weaken ]; then echo ignore=E >> .style.cfg; fi']"
    And the Intent "is-even" from fixture "is-even" is approved
    And the file ".kogen/local/weaken" is changed outside Kogen
    When the caller runs "kogen intent build is-even"
    Then the exit code is 1
    And stdout contains "candidate/baseline_changed: the Build changed acceptance files: .style.cfg; nothing was committed"
    And the fake ChatGPT server received 0 requests
    And HEAD is unchanged

  @AUT-5
  Scenario: A check that already fails on the unchanged tree is recorded as a baseline and the Build repairs it
    Given the project config sets "commands.checks" to "[{name: has-is-even, run: 'grep -q is_even calc.py'}]"
    And the Intent "is-even" from fixture "is-even" is approved
    And the fake ChatGPT server plays script "build-correct-first-try"
    When the caller runs "kogen intent build is-even"
    Then the exit code is 0
    And stdout contains "baseline: 1 of 1 configured check(s) fail before the Build changes anything"
    And stdout contains "check has-is-even (grep -q is_even calc.py) failed (status=1)"
    And stdout contains "landed is-even "
    And stdout contains "1. has-is-even: failed (status=1) → passed"
    And HEAD has 1 new commit

  @AUT-5
  Scenario: A baseline failure is never a waiver and an unverified check is not run
    Given the project config sets "commands.checks" to "[{name: broken, run: 'false'}]"
    And the Intent "is-even" from fixture "is-even" is approved
    And the fake ChatGPT server plays script "build-then-500-always"
    When the caller runs "kogen intent build is-even"
    Then the exit code is 4
    And stdout contains "check broken (false) failed (status=1)"
    And stdout contains "1. broken: failed (status=1) → not run"
    And stdout does not contain "landed is-even"
    And HEAD is unchanged

  @AUT-6 @GIT-1
  Scenario: After a Build without a commit, the next build waits for the caller to handle the edits
    Given the Intent "is-even" from fixture "is-even" is approved
    And the fake ChatGPT server plays script "build-context-overflow"
    And the caller ran "kogen intent build is-even"
    When the caller runs "kogen intent build is-even"
    Then the exit code is 5
    And stdout contains "environment/dirty_tree: 1 changed path(s) are not part of an Intent"
    Given the caller discards the edits listed in the last Build output
    And the fake ChatGPT server plays script "build-correct-first-try"
    When the caller runs "kogen intent build is-even"
    Then the exit code is 0
    And stdout contains "landed is-even "
    And the file ".kogen/local/approvals/is-even.json" does not exist
