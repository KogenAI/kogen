Feature: Shape checks each stated Decision against the request
  The driver mounts as a test with go -overlay and runs the real native Shape path against a scripted provider, then the real approval card. The request is "Add calc.is_even(n). Example: is_even(0) returns True. Non-integers raise TypeError." The scripted decision check is the one provider call whose only tool is submit_decision_check.

  Scenario: A Decision contradicting an explicit request example is fed back and the corrected submission publishes
    When the k26 Shape plays "contradict"
    Then the k26 observation satisfies the contract of its mode

  Scenario: A Decision whose request quote is not in the request is treated as unsupported
    When the k26 Shape plays "unsupported"
    Then the k26 observation satisfies the contract of its mode

  Scenario: An assumption Decision publishes and appears on the approval card
    When the k26 Shape plays "assumption"
    Then the k26 observation satisfies the contract of its mode

  Scenario: Without shape_decision_check requests, events and the card are unchanged
    When the k26 Shape plays "off"
    Then the k26 observation satisfies the contract of its mode

  Scenario: An unknown key under shape_decision_check is refused before any provider request
    When the k26 Shape plays "badkey"
    Then the k26 observation satisfies the contract of its mode
