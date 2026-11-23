Feature: A future harness check timestamp is due
  This feature covers Harness.due in cli/internal/claudecode, which decides whether the daily Claude Code harness check is due.

  Scenario: A checked_at later than now is due
    Given future-harness-check-is-due: a throwaway Harness.due test is overlaid on the claudecode package
    When future-harness-check-is-due: that test runs in the claudecode package
    Then future-harness-check-is-due: a checked_at one hour later than now is due
