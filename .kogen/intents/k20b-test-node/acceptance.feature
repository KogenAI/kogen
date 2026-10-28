Feature: Shape tests use an absolute Node, not the one on PATH

  Scenario: a HOME-dependent node shim on PATH does not break the shape tests
    Given a node shim first on PATH that fails when HOME differs from the original HOME
    When go test runs the untrusted-document shape test with that PATH and no KOGEN_NODE
    Then the go test run passes
    And the shim was invoked at least once and never under a different HOME
