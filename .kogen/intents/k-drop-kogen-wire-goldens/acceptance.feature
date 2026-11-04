Feature: Drop kogen's executor and loop wire tests
  Scenario: Remove the executor and loop wire tests from kogen
    Then k-drop-kogen-wire-goldens: the specification file "spec/features/08-chatgpt.feature" still has the scenario "The compatible login reads the base URL, then the key, and binds the key to that origin"
    And k-drop-kogen-wire-goldens: the specification file "spec/features/08-chatgpt.feature" still has the scenario "The compatible login refuses an HTTP base URL and keeps a keyless localhost host login-free"
    And k-drop-kogen-wire-goldens: these paths are absent from the checkout:
      | cli/research_removal_test.go        |
      | cli/testdata/loop_knobs_golden.json |
      | cli/response_budget_test.go         |
      | cli/compatible_login_test.go        |

  Scenario: The cli package lists no wire tests and keeps its installed-binary checks
    When k-drop-kogen-wire-goldens: I list the tests of the cli package
    Then k-drop-kogen-wire-goldens: the cli test listing succeeds
    And k-drop-kogen-wire-goldens: the cli test listing still names:
      | TestInstalledKeyLoginUnderPipesAndATerminal               |
      | TestUsageLimitResumeInstalledRound2                       |
      | TestUsageLimitResumeInstalledRound3                       |
      | TestUsageLimitPackagingIsolationRound2                    |
      | TestUsageLimitPackagingIsolationRound3                    |
      | TestInstalledBinaryAnswersTheHookBeforeAnyOtherStartup    |
      | TestInstalledProbeDeadline                                |
      | TestObservationRejectsAnInstalledReleaseWithoutItsProgram |
    And k-drop-kogen-wire-goldens: the cli test listing names none of:
      | TestResearchRemovalDefaults        |
      | TestShapeBudgetRoleContract        |
      | TestCompatibleLoginUserOrigin      |
      | TestCompatibleLoginRoleOrigins     |
      | TestCompatibleLoginLegacyOriginHint |
      | TestCompatibleLoginContractText    |
