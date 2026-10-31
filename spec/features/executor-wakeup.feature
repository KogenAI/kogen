# LOOP-14/LOOP-15: a Claude Code builder awaits its commands within its round instead of scheduling
# a later wakeup. The fake claude is a Node script, not a model; it honors the --disallowedTools it
# receives, and no live provider or account is used.
@executor-wakeup
Feature: Claude Code wakeups stay within Build rounds
  Scheduled wakeups are unavailable to a Build session; long commands are awaited in the round and
  every other event after a result is still a protocol failure.

  Background:
    Given a clean Kogen home
    And the installed kogen command
    And a Git project from fixture "py-calc"
    And the project is initialized and configured
    And the project config sets "models.build" to "{executor: claude-code, model: claude-opus-5-5, effort: high}"
    And the project config sets "models.review" to "{executor: claude-code, model: claude-opus-5-5, effort: high}"
    And the Intent "is-even" from fixture "is-even" is approved

  @LOOP-14 @LOOP-15
  Scenario: A scheduled wakeup cannot escape the builder round
    Given a fake claude with script "wakeup-scheduled" is on PATH
    When the caller runs "kogen intent build is-even"
    Then the exit code is 0
    And HEAD has 1 new commit
    And the committed contents of "calc.py" contain "isinstance"
    And the fake claude builder recorded a wakeup attempt, its denial and its command completing before the result
    And the Build role of the run log has 1 executor round with a claim containing "WAKEUP-BUILDER-CLAIM"
    And the run log shows an independent review executor round
    And fake claude role "review" ran 1 invocation
    And the run log records no executor protocol stop

  @LOOP-14 @LOOP-15
  Scenario: A long command returns its result within the builder round
    Given a fake claude with script "wakeup-long" is on PATH
    When the caller runs "kogen intent build is-even"
    Then the exit code is 0
    And HEAD has 1 new commit
    And the fake claude builder recorded its long command output and exit status before the result
    And the Build role of the run log has 1 executor round with a claim containing "WAKEUP-BUILDER-CLAIM"

  @LOOP-14 @LOOP-15
  Scenario: A non-scheduling event after result still stops the Build
    Given a fake claude with script "wakeup-trailing" is on PATH
    When the caller runs "kogen intent build is-even"
    Then the exit code is 1
    And stdout contains "executor/protocol"
    And HEAD is unchanged
