Feature: Keep the yield snapshot regressions passing
  Scenario Outline: Existing shell lifecycle, retrieval and attempt cleanup keep passing
    Then the yield snapshot regression "<test>" in package "<package>" ran and passed

    Examples:
      | test                             | package       |
      | TestShellLifecycleSuccessCleanup | ./conformance |
      | TestShellYieldRetrievalScope     | ./tools       |
