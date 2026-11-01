Feature: Adapt Kogen to loop 1a3eb18
  The vendor and pin already exist and remain unchanged. Focused tests exercise
  actual native Build and Review paths as well as the intentionally changed wire
  fixtures; the full configured checks remain the final Build gate.

  Scenario Outline: Pin-induced regressions pass without losing coverage
    When repin adaptation runs "<test>" in "<package>"
    Then repin adaptation observed "<test>" run and pass

    Examples:
      | package | test                                       |
      | ./agent | TestDefinitionsMatchTheElixirDefinitions    |
      | .       | TestResearchRemovalDefaults                |
      | ./build | TestKRevodGatePartsUnchanged                |
      | ./build | TestSilentBuildShellNotStopped             |
      | ./build | TestSilentReviewShellNotStopped            |
      | ./build | TestNativeConformance                     |
      | ./build | TestNamedFeedbackCompatibility             |
      | ./build | TestKReviewRetryUnchangedValidRequests      |
