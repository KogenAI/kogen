Feature: calc.is_even

  Scenario: Even numbers
    Given the input is 4
    When I check is_even
    Then result is True

  Scenario: Odd numbers
    Given the input is 3
    When I check is_even
    Then result is False

  Scenario: Non-integers
    Given the input is 1.5
    When I check is_even
    Then a TypeError is raised
