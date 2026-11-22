Feature: Readiness report formatting is tested for every status
  This feature checks the Go tests of the readiness report formatter by running them against the real formatter and against deliberately wrong variants of it.

  Scenario: An empty report prints nothing
    Then readiness-report-non-failure-format-tests: the readiness tests reject a Text that prints a header for no checks
    And readiness-report-non-failure-format-tests: the readiness tests reject a Text that prints a stray newline for no checks

  Scenario: A non-failure status prints no fix line
    Then readiness-report-non-failure-format-tests: the readiness tests reject a Text that adds a fix line to every status other than ok

  Scenario: The mixed-status test keeps asserting the failure-only fix rule
    Then readiness-report-non-failure-format-tests: the readiness package tests pass and the existing TestText runs once and passes
    And readiness-report-non-failure-format-tests: the existing TestText fails for a Text that adds a fix line to every status
    And readiness-report-non-failure-format-tests: the existing TestText fails for a Text that never adds a fix line
