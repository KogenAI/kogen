Feature: Adapt Kogen to kogen-loop f2e30a4
  The re-pin commit already holds the vendored loop and cli/loop-pin.json; both stay
  unchanged. With f2e30a4 a new shell command waits up to 45 seconds, so the tests that used
  a two-second command to obtain a running handle now use "sleep 47", which genuinely
  outlasts that wait: the default building shell still proves end to end that it is
  unbounded, and the silent Build and Review shell tests keep that command and every
  assertion (the configured go-test check runs them). The specification states the
  45-second wait. The configured checks remain the final Build gate.

  Scenario: The default building shell still yields past the 45-second wait and is retrieved to completion
    When f2e30a4 adaptation runs the building scenario "Default shell calls remain unbounded"
    Then f2e30a4 adaptation observed that building scenario run once and pass
    And f2e30a4 adaptation finds that building scenario tagged "@LOOP-5 @LOOP-11" with these steps:
      | step                                                                                   |
      | Given the Intent "is-even" from fixture "is-even" is approved                          |
      | And the fake ChatGPT server plays script "build-runs-command" with command "sleep 47"  |
      | When the caller runs "kogen intent build is-even"                                      |
      | Then the tool result for "shell sleep 47" contains "running"                           |
      | And the tool result for "shell continuation" contains "completed"                      |
      | And the exit code is 0                                                                 |

  Scenario: The silent shell tests keep their command past the wait and every assertion
    Then f2e30a4 adaptation finds "cli/build/silent_shell_test.go" contains these texts:
      | text                                            |
      | const silentCommand = "sleep 47; printf 'done   |
      | case "running":                                 |
      | case "completed":                               |
      | map[string]any{"handle": handle}                |
      | the handle was not retrieved                    |
      | review requests: the handle was not retrieved   |
      | "command_no_progress"                           |

  Scenario: The specification states the pinned shell waits
    Then f2e30a4 adaptation finds the "LOOP-5" paragraph of "spec/prose/04-building.md" contains "45 seconds"
    And f2e30a4 adaptation finds the "LOOP-5" paragraph of "spec/prose/04-building.md" contains "30 seconds"
    And f2e30a4 adaptation finds the "LOOP-5" paragraph of "spec/prose/04-building.md" does not contain "one second"
    And f2e30a4 adaptation finds the "LOOP-5" paragraph of "spec/prose/04-building.md" does not contain "first second"

  Scenario: Kogen's tests no longer describe a one-second shell wait
    Then f2e30a4 adaptation finds none of these texts in Kogen's tests outside the vendored loop:
      | text                    |
      | one-second wait         |
      | yields after one second |
