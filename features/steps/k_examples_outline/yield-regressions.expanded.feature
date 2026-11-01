Feature: Keep the yield snapshot regressions passing
  Scenario: Existing shell lifecycle, retrieval and attempt cleanup keep passing
    Then the yield snapshot regression "TestShellLifecycleSuccessCleanup" in package "./conformance" ran and passed

  Scenario: Existing shell lifecycle, retrieval and attempt cleanup keep passing
    Then the yield snapshot regression "TestShellYieldRetrievalScope" in package "./tools" ran and passed
