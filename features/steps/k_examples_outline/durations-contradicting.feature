Feature: Render durations in words
  Scenario Outline: <seconds> seconds render as hours, minutes and seconds
    Given the input '<seconds>'
    Then the output is '<words>'

    Examples:
      | seconds | words                        |
      | 3725    | 1 hour, 2 minutes, 5 seconds |
      | 5430    | 1 hour, 1 minute, 30 seconds |
