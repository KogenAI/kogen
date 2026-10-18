Feature: bounded counter

  Scenario: Counter starts at zero
    Given the counter is initialized
    Then its value is non-negative
