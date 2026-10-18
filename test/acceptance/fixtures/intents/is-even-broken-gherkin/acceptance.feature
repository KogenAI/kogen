Feature: calc.is_even

  Scenario: Even numbers
    Given the input is 4
    When I check is_even
    Then result is True
  This is not a Gherkin step
