Feature: calc.is_even

  Scenario Outline: Result for <kind> values
    Given the input is <value>
    When I check is_even
    Then result is <result>

    Examples:
      | kind | value | result |
      | even | 4     | True   |
      | odd  | 3     | False  |
      | even | 2     | True   |
