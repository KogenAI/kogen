Feature: Remove the approval-time example check
  Scenario: A format-only expected value no longer blocks Shape or approval
    Given the removed check compared these format-only values:
      | expected                         | derived                            |
      | "status":0,"out":"61610a0a"      | {"status":0,"out":"61610a0a"}        |
    When I run the focused example-removal Shape and approval regression
    Then the example-removal regression ran once and passed
