Feature: Render durations in words
  Scenario: 3725 seconds render as hours, minutes and seconds
    Given the input '3725'
    Then the output is '1 hour, 2 minutes, 5 seconds'

  Scenario: 5430 seconds render as hours, minutes and seconds
    Given the input '5430'
    Then the output is '1 hour, 30 minutes, 30 seconds'
