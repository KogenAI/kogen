Feature: calculator addition

  Scenario: add two integers
    Given the calculator accepts 2 and 3
    When I add the calculator arguments
    Then the calculator result is 5
