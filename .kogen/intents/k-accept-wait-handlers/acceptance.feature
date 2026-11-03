Feature: The fake-server wait ends on the awaited request or on the kogen process ending
  The acceptance step "the fake ChatGPT server has sent the feedback of verification pass N" waits for the fake
  ChatGPT server to receive the request containing "Verification pass N is not green.". Under host load its fixed
  wait (30 seconds, or 5 seconds per pass) failed whole adoption windows on 04-building.feature:105, waiting for
  verification pass 25. The wait now ends on that request or on the kogen process ending: a slow host slows the
  scenario instead of failing it, and a kogen process that ended without the request still fails it, naming the
  missing request. The real step handler of test/acceptance/support/handlers.js is driven against real child
  processes standing in for the background kogen command.

  Scenario: A request that arrives after the old fixed wait ends the wait instead of failing the scenario
    When the fake-server wait is observed through the acceptance step handler
    Then the wait for verification pass 1 ends on its request that arrives 31 seconds later while the kogen process runs
    And a request already recorded ends the wait at once
    And a request recorded just before the kogen process ends is found
    And spec/features/04-building.feature still has the scenario "Ordinary implementation failures keep repairing until the caller stops it" with exactly these steps:
      """
      Given the Intent "is-even" from fixture "is-even" is approved
      And the fake ChatGPT server plays script "build-wrong-forever"
      And the caller runs "kogen intent build is-even" in the background
      When the fake ChatGPT server has sent the feedback of verification pass 25
      Then the kogen command is still running
      When the caller sends SIGINT to the kogen command
      Then the exit code is 130
      And HEAD is unchanged
      """

  Scenario: A kogen process that ended without the request fails the wait, naming the missing request
    When the fake-server wait is observed through the acceptance step handler
    Then the wait for verification pass 7 fails soon after the kogen process ends, naming "Verification pass 7 is not green."
    And with no kogen process running the wait for verification pass 2 fails at once, naming "Verification pass 2 is not green."
