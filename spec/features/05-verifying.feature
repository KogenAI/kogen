Feature: Verifying and repair
  Green comes only from executed checks; failures go back to the builder;
  the approved acceptance baseline cannot be weakened.

  Background:
    Given a clean Kogen home
    And the installed kogen command
    And a Git project from fixture "py-calc"
    And the project is initialized and configured
    And the caller is signed in to ChatGPT

  @VER-6 @VER-7 @VER-13 @model:build
  Scenario: A failing pass goes back to the builder and the repair lands
    Given the Intent "is-even" from fixture "is-even" is approved
    And the fake ChatGPT server plays script "build-wrong-then-repair"
    When the caller runs "kogen intent build is-even"
    Then the exit code is 0
    And stdout contains "repairs: 1"
    And the request after verification pass 1 contains "Odd numbers"
    And the request after verification pass 1 contains "AssertionError"
    And the run log shows fix-1 once before verification pass 1

  @VER-3 @VER-4 @VER-13
  Scenario: The acceptance command gets the feature and the report path, and every scenario must pass exactly once
    Given the Intent "is-even" from fixture "is-even" is approved
    And the acceptance command records its environment
    And the fake ChatGPT server plays script "build-correct-first-try"
    When the caller runs "kogen intent build is-even"
    Then the exit code is 0
    And the recorded acceptance environment has KOGEN_ACCEPTANCE_FEATURES set to ".kogen/intents/is-even/acceptance.feature"
    And the recorded acceptance environment has KOGEN_ACCEPTANCE_REPORT inside ".kogen/local/runs/"
    And stdout contains "checks: acceptance 3/3"

  @VER-4
  Scenario Outline: A report that is not a clean pass is a failing check
    Given the Intent "is-even" from fixture "is-even" is approved
    And the acceptance command is replaced by fixture runner "<runner>"
    And the fake ChatGPT server plays script "build-correct-first-try"
    And the caller runs "kogen intent build is-even" in the background
    When the fake ChatGPT server has sent the feedback of verification pass 1
    Then the request after verification pass 1 contains "<problem>"
    When the caller sends SIGINT to the kogen command
    Then HEAD is unchanged

    Examples:
      | runner             | problem                          |
      | reports-undefined  | undefined                        |
      | reports-skipped    | skipped                          |
      | omits-one-scenario | missing                          |
      | reports-one-twice  | duplicate                        |
      | writes-no-report   | report_missing                   |
      | exits-1-all-passed | exit 1 with all scenarios passed |

  @VER-5 @LOOP-12
  Scenario: Quint runs with Kogen's own Node, never the node first on the caller's PATH
    Given the Intent "counter" from fixture "counter-with-model" is approved
    And a broken program "node" is first on PATH
    And the fake ChatGPT server plays script "build-correct-first-try"
    When the caller runs "kogen intent build counter"
    Then the exit code is 0
    And the run log shows Quint ran with the Node recorded in the installation's node-path file

  @VER-5
  Scenario: A Quint model is checked with its recorded seed and bounds
    Given the Intent "counter" from fixture "counter-with-model" is approved
    And the fake ChatGPT server plays script "build-correct-first-try"
    When the caller runs "kogen intent build counter"
    Then the exit code is 0
    And the run log shows the command "quint run .kogen/intents/counter/model.qnt --backend typescript --invariant NeverNegative --seed 7 --max-samples 500 --max-steps 30"

  @VER-8 @VER-12 @model:build
  Scenario Outline: Weakening the baseline is refused or stops the Build at once
    Given the Intent "is-even" from fixture "is-even" is approved
    And the fake ChatGPT server plays script "build-runs-command" with command "<command>"
    When the caller runs "kogen intent build is-even"
    Then the exit code is 1
    And stdout contains "candidate/baseline_changed: the Build changed acceptance files: <path>; nothing was committed"
    And no request was sent after that command
    And HEAD is unchanged

    Examples:
      | command                                                                | path                                      |
      | echo '  # weakened' >> .kogen/intents/is-even/acceptance.feature     | .kogen/intents/is-even/acceptance.feature |
      | echo pass > features/steps/is_even_steps.js                            | features/steps/is_even_steps.js           |
      | echo ignore=E >> .style.cfg                                            | .style.cfg                                |

  @VER-8 @LOOP-4
  Scenario: write_file refuses a protected path and the Build goes on
    Given the Intent "is-even" from fixture "is-even" is approved
    And the fake ChatGPT server plays script "build-tries-path" with path ".kogen/intents/is-even/acceptance.feature"
    When the caller runs "kogen intent build is-even"
    Then the tool result for "write_file .kogen/intents/is-even/acceptance.feature" is "refused: .kogen/intents/is-even/acceptance.feature is part of the approved acceptance baseline"
    And the exit code is 0

  @VER-9 @model:build
  Scenario: A check that rewrites source makes the pass not green
    Given the project config sets "commands.checks" to "[{name: fmt, run: python3 tools/format.py --write}]"
    And the Intent "is-even" from fixture "is-even" is approved
    And the fake ChatGPT server plays script "build-unformatted-then-formatted"
    When the caller runs "kogen intent build is-even"
    Then the request after verification pass 1 contains "files changed while checks ran: calc.py"
    And the exit code is 0

  @VER-10
  Scenario: Ignored outputs are not part of the candidate or the commit
    Given the Intent "is-even" from fixture "is-even" is approved
    And the fake ChatGPT server plays script "build-correct-first-try"
    When the caller runs "kogen intent build is-even"
    Then the exit code is 0
    And the folder "__pycache__" exists
    And the new commit changes no path under "__pycache__/"
