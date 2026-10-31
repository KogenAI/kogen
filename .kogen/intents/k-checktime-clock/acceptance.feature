Feature: Remove avoidable waits without losing clock evidence
  Scenario Outline: Readiness replaces padding through the real test harness
    When clock acceptance runs "TestChecktimeClockReadiness" in package "<package>"
    Then clock acceptance observes "TestChecktimeClockReadiness" ran once and passed
    Examples:
      | package |
      | ./build |
      | ./shape |

  Scenario: Preserve measured delivery accounting
    Then the clock measurement note exists at "test/checktime-clock.md"
