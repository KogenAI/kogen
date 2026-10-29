Feature: Ten-minute provider response default
  Kogen lowers the existing absolute provider wait without changing requests or retries.

  Scenario: All provider-backed entries use and report the shared default
    When I run the loop knob contract test "TestResponseBudgetDefaultContract" in "cli"
    Then the loop knob contract test "TestResponseBudgetDefaultContract" passes

  Scenario: The pinned provider retains its independent contract
    When I run the pinned loop race suite
    Then the pinned loop race suite succeeds
