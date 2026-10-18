Feature: calc.is_even
  Scenario: Even numbers
    Given the input is 4
    When I check is_even
    Then result is True
  Scenario: Odd numbers
    Given the input is 3
    When I check is_even
    Then result is False
  Scenario: Undefined caller step
    Given the input is 4
    When the caller doubles 4
    Then result is True
