Feature: kogen's qualification is green on the new component tuple
  The base is the pin commit 85b5c519a472 with every component at its newest main:
  kogen-coordinator e91a9e0ac65b -> 7e4fcd1a50a8, kogen-verification 67617548616c -> 25884c52dde4,
  kogen-shaping 7bcfc8d32b83 -> cb9498a719ef, kogen-executor 55b372c4dd31 -> 5e9ca167fa44.
  At the base, go test ./... in cli failed because kogen-verification now refuses an install whose
  node-path file is missing or names a Node that is not an executable regular file (exit 3,
  environment/tool_missing), and because kogen-executor now pins Claude Code 2.1.318 instead of 2.1.312.
  The slowest failing tests, TestApproveDeadlineHungCLI and TestApproveDeadlineSplitCLI, each wait
  more than 120 seconds when they pass; the configured go-test check runs them.

  Scenario: The pins stay as adopted and the kogen-shaping consumer suite passes
    Then k-integrate-pins-20261107t120002z: the cli module resolves the components:
      | module                                | version                                    |
      | github.com/KogenAI/kogen-loop         | v0.0.0 => ./third_party/kogen-loop         |
      | github.com/KogenAI/kogen-coordinator  | v0.0.0-20261107083354-7e4fcd1a50a8         |
      | github.com/KogenAI/kogen-verification | v0.0.0-20261107101842-25884c52dde4         |
      | github.com/KogenAI/kogen-shaping      | v0.0.0-20261107074600-cb9498a719ef         |
      | github.com/KogenAI/kogen-build        | v0.0.0-20261106191737-45d5823fa40c         |
      | github.com/KogenAI/kogen-executor     | v0.0.0-20261107093550-5e9ca167fa44         |
      | github.com/KogenAI/kogen-setup        | v0.0.0-20261106184805-43be668ea101         |
      | github.com/KogenAI/kogen-review       | v0.0.0-20261106124750-cdcbbe3e357a         |
    And k-integrate-pins-20261107t120002z: the loop pin names module "github.com/KogenAI/kogen-loop" at source head "84ee1ed6652fd8af15a33e5e5c268a89ea2564c9"
    And k-integrate-pins-20261107t120002z: gofmt lists no file in cli
    And k-integrate-pins-20261107t120002z: "go build ./..." in "cli" succeeds
    And k-integrate-pins-20261107t120002z: "go vet ./..." in "cli" succeeds
    When k-integrate-pins-20261107t120002z: go test runs package "./consumes/kogen-shaping" in cli matching ""
    Then k-integrate-pins-20261107t120002z: the package passed with each of these tests run once and passed:
      | test                                                                            |
      | TestApproveWithoutAHashShowsTheCardWithExit5                                    |
      | TestApproveRunsTheAcceptanceCommandWithTheTools                                 |
      | TestApproveWithTheHashPublishesTheApproval                                      |
      | TestApproveWithTheHashPublishesTheApproval/full_hash,_Git_identity              |
      | TestApproveWithTheHashPublishesTheApproval/six_characters,_named_approver       |
      | TestApproveRefusalsAreSysErrorsWithTheirExit                                    |
      | TestApproveRefusalsAreSysErrorsWithTheirExit/hash_does_not_match                |
      | TestApproveInterruptExitsWithTheSignalsCode                                     |
      | TestPreflightJSONShowsTheCheckoutAndTheBlockers                                 |
      | TestPreflightTextReportsTheState                                                |
      | TestRefineAsksKogensExecutorForAnExternalShapeRole                              |
      | TestRefineAsksKogensExecutorForAnExternalShapeRole/an_error                     |
      | TestRefineAsksKogensExecutorForAnExternalShapeRole/no_executor                  |
      | TestRefineAsksKogensExecutorForAnExternalShapeRole/not_provided                 |
      | TestRefineInterruptExitsWithTheSignalsCode                                      |
      | TestRefineRefusalsAreSysErrorsWithTheirExit                                     |
      | TestRefineRefusalsAreSysErrorsWithTheirExit/hash_is_not_the_full_hash           |
      | TestRefineRefusalsAreSysErrorsWithTheirExit/hash_is_stale                       |
      | TestRefineRefusalsAreSysErrorsWithTheirExit/not_signed_in                       |

  Scenario: The kogen-verification consumer suite states that an install without node-path has no Node
    When k-integrate-pins-20261107t120002z: go test runs package "./consumes/kogen-verification" in cli matching ""
    Then k-integrate-pins-20261107t120002z: the package passed with each of these tests run once and passed:
      | test                                                  |
      | TestToolsFromInstallNamesTheNodeOfTheInstall          |
      | TestToolsFromInstallWithoutNodePathFile               |
      | TestToolsFromInstallLocatesQuintAndCucumberUnderLib   |
    And k-integrate-pins-20261107t120002z: the file "cli/consumes/kogen-verification/README.md" contains none of these texts:
      | text                                         |
      | is that file's own path                      |

  Scenario: The readiness package checks the pinned Claude Code 2.1.318
    When k-integrate-pins-20261107t120002z: go test runs package "./readiness" in cli matching ""
    Then k-integrate-pins-20261107t120002z: the package passed with each of these tests run once and passed:
      | test                                                          |
      | TestClaudeChecks                                              |
      | TestClaudeChecks/another_sign-in_route_is_no_subscription     |
      | TestClaudeChecks/another_version_names_the_path_and_the_fix   |
      | TestClaudeChecks/not_signed_in                                |
      | TestClaudeChecks/pinned_with_subscription_sign-in             |
      | TestClaudeChecks/stored_token_replaces_sign-in                |

  Scenario: Builds through the program binary pass with an install that has a Node
    When k-integrate-pins-20261107t120002z: go test runs package "./buildprogram" in cli matching "^TestSatisfiedRebuild(AlreadyPresent|PreservesStagedIntent)$"
    Then k-integrate-pins-20261107t120002z: the package passed with each of these tests run once and passed:
      | test                                      |
      | TestSatisfiedRebuildAlreadyPresent        |
      | TestSatisfiedRebuildPreservesStagedIntent |

  Scenario: The installed-release and runtime-line tests run on the pinned Claude Code
    When k-integrate-pins-20261107t120002z: go test runs package "." in cli matching "^(TestProviderListRuntimeLine|TestUsageLimitResumeInstalledRound2|TestUsageLimitResumeInstalledRound3|TestUsageLimitPackagingIsolationRound2|TestUsageLimitPackagingIsolationRound3)$"
    Then k-integrate-pins-20261107t120002z: the package passed with each of these tests run once and passed:
      | test                                    |
      | TestProviderListRuntimeLine             |
      | TestUsageLimitResumeInstalledRound2     |
      | TestUsageLimitResumeInstalledRound3     |
      | TestUsageLimitPackagingIsolationRound2  |
      | TestUsageLimitPackagingIsolationRound3  |

  Scenario: Every statement of the pinned Claude Code version follows kogen-executor
    Then k-integrate-pins-20261107t120002z: no file under these directories contains "2.1.312":
      | directory         |
      | cli               |
      | docs              |
      | spec              |
      | test              |
      | packaging         |
      | features/steps    |
    And k-integrate-pins-20261107t120002z: the file "test/acceptance/support/executor-steps.js" contains each of these texts:
      | text                     |
      | const PINNED = '2.1.318'; |
    And k-integrate-pins-20261107t120002z: the file "test/acceptance/fixtures/claude/fake-claude.js" contains each of these texts:
      | text                          |
      | 2.1.318 (Claude Code)         |
    And k-integrate-pins-20261107t120002z: the file "spec/prose/04-building.md" contains each of these texts:
      | text                                       |
      | version `2.1.318`                          |
    And k-integrate-pins-20261107t120002z: the file "docs/executor-contract.md" contains each of these texts:
      | text                                       |
      | must start with `2.1.318`                  |

  Scenario: The specification and the shaping consumer README state the install checks
    Then k-integrate-pins-20261107t120002z: the file "spec/prose/04-building.md" contains each of these texts:
      | text                                |
      | names a regular executable file     |
    And k-integrate-pins-20261107t120002z: the file "cli/consumes/kogen-shaping/approve_test.go" contains each of these texts:
      | text                                |
      | environment/tool_missing            |
    And k-integrate-pins-20261107t120002z: the file "cli/consumes/kogen-shaping/README.md" contains each of these texts:
      | text                                |
      | environment/tool_missing            |
