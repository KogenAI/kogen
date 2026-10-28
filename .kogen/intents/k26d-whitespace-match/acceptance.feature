Feature: Whitespace-insensitive matching and last-attempt title shortening

  Scenario: Comparison rules, audit coverage and title shortening helper
    When the k26d Shape plays "unit"
    Then the k26d observation satisfies the contract of its mode

  Scenario: Quotes from a hard-wrapped request count as follows on the first attempt
    When the k26d Shape plays "wrap"
    Then the k26d observation satisfies the contract of its mode

  Scenario: A 62-character title is shortened on the last attempt
    When the k26d Shape plays "title_last"
    Then the k26d observation satisfies the contract of its mode

  Scenario: The same title problem on attempt 1 is fed back
    When the k26d Shape plays "title_first"
    Then the k26d observation satisfies the contract of its mode
