Feature: Prevent Claude Code wakeups outside Build rounds
  A builder awaits its commands within its round instead of scheduling a later wakeup.

  Scenario: Deny scheduling without disabling long commands or weakening protocol
    When I execute the focused loop boundary tests:
      | module | package | test |
      | cli | ./executor/claudecode | TestBuildWakeupDeniedEveryRound |
      | cli | ./executor/claudecode | TestBuildLongCommandWithinRound |
      | cli | ./executor/claudecode | TestBuildTrailingEventStillProtocol |
    Then each focused loop boundary test executes and passes once

  Scenario: Exercise scheduling and its counterexamples through the shipped binary
    When I execute the installed loop specifications tagged "@executor-wakeup" in:
      | spec/features/executor-wakeup.feature |
    Then exactly these installed loop scenarios execute with every step passing:
      | A scheduled wakeup cannot escape the builder round |
      | A long command returns its result within the builder round |
      | A non-scheduling event after result still stops the Build |
