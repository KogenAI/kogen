Feature: Portable probe home emptiness assertion
  Scenario: Preserve the real environment wiring test
    Then the probe count Go test "TestShapeProbeMinimalEnvironmentWiring" passes

  Scenario Outline: Recognize the home count without depending on wc padding
    # These literals reproduce GNU and BSD count formatting.
    Given the probe count regression case "<case>" represents count "<count>" with emptiness "<empty>"
    Then the probe count Go test "TestShapeProbeHomeEmptinessRegression/<case>" passes

    Examples:
      | case         | count    | empty |
      | unpadded-zero | 0       | true  |
      | padded-zero   |        0 | true  |
      | unpadded-one  | 1       | false |
      | padded-one    |        1 | false |
