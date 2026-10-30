Feature: Build repairs checks that already fail
  Baseline failures are visible diagnostics, not permission to land red.

  Scenario Outline: Fixture Builds preserve the all-green landing rule
    Then the failing-check fixture test "<test>" passes

    Examples:
      | test                                |
      | TestFailingCheckBuildRepair          |
      | TestFailingCheckBuildEvidence        |
      | TestFailingCheckBuildUnrelated       |
      | TestFailingCheckBuildRegression      |
