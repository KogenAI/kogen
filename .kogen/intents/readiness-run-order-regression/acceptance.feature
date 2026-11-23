Feature: The readiness Run report is covered by direct tests
  This feature checks the Go tests of the public readiness Run function by running them against the real Run and against deliberately wrong variants of it.

  Scenario: A configured project inside a Git checkout reports in order and checks the repository root
    Then readiness-run-order-regression: the readiness package tests pass
    And readiness-run-order-regression: the readiness tests reject a Run that returns the checks out of order
    And readiness-run-order-regression: the readiness tests reject a Run that checks the nested working directory instead of the repository root

  Scenario: A project outside a Git checkout still reports all four checks
    Then readiness-run-order-regression: the readiness tests reject a Run that returns early after the Git failure
    And readiness-run-order-regression: the readiness tests reject a Run that checks the parent of a project outside Git
