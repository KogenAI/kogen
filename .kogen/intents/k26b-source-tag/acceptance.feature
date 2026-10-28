Feature: Decision-check and audit feedback keep the required source tag
  The driver mounts as a test with go -overlay and runs the real native Shape path against a scripted provider (shaper, decision check, request audit), then the real approval card. In the first scenario the request is "Add calc.is_even(n). Example: is_even(0) returns True. Non-integers raise TypeError." and the shaper first states the unsupported Decision "- Zero counts as even. (source: request)". In the others the request holds the example "Example: is_even(0) returns True." and the rule "Rule B: zero returns False.".

  Scenario: A shaper that follows the decision-check feedback literally keeps the source tag and the card lists the assumption
    When the k26b Shape plays "assume"
    Then the k26b observation satisfies the contract of its mode

  Scenario: A shaper that pastes the audit template covers the defect and passes readiness
    When the k26b Shape plays "paste"
    Then the k26b observation satisfies the contract of its mode

  Scenario: Reshaping the same slug with the audit off shows no stale conflicts section
    When the k26b Shape plays "stale"
    Then the k26b observation satisfies the contract of its mode

  Scenario: Reshaping the same slug with every defect covered shows no stale conflicts section
    When the k26b Shape plays "stale_covered"
    Then the k26b observation satisfies the contract of its mode
