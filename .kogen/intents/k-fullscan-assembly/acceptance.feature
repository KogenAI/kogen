Feature: Qualify the current component assembly without changing components
  Scenario: Complete deterministic gates qualify the exact assembled tuple
    When k-fullscan-assembly: I run the complete deterministic assembly qualification
    Then k-fullscan-assembly: all gates pass and all 266 specification scenarios and their steps pass
