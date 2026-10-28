Feature: Mode-correct reviewer reset handoffs
  Scenario: On-demand long review resets and approves without reading parts
    When the krevodb regression "TestKRevodBOnDemandReset" runs
    Then the krevodb regression passes with reset sentence "Read only the parts you need; no part is required before a verdict."

  Scenario: Default parts long review retains its original handoff bytes
    When the krevodb regression "TestKRevodBPartsReset" runs
    Then the krevodb regression passes with reset sentence "Kogen also appends unread pinned parts as native source data messages; they count once a completed response follows them."
