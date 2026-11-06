Feature: kogen's installed-binary tests are hermetic and share one release per package test run
  The installed-login test never needs GitHub or a PATH interpreter and still catches broken login
  custody. Each Go package test run packages one release, shared read-only by its installed tests,
  which still catch a broken installed binary and stale packaged source. Every Go run happens in a
  scratch copy of this checkout; deliberately broken implementations exist only in those copies.

  Background:
    Given kogen-checks-stall-kogen-builds: the installed-test runs have started in scratch copies of this checkout

  Scenario: The installed-login test passes with GitHub unreachable
    When kogen-checks-stall-kogen-builds: the "hermetic login" run finishes
    Then kogen-checks-stall-kogen-builds: the run passed these Go tests:
      | test                                                                              |
      | TestInstalledKeyLoginUnderPipesAndATerminal                                       |
      | TestInstalledKeyLoginUnderPipesAndATerminal/opencode-go_piped_invalid_UTF-8       |
      | TestInstalledKeyLoginUnderPipesAndATerminal/opencode-go_terminal                  |
      | TestInstalledKeyLoginUnderPipesAndATerminal/anthropic_piped_invalid_UTF-8         |
      | TestInstalledKeyLoginUnderPipesAndATerminal/anthropic_terminal                    |
      | TestInstalledKeyLoginUnderPipesAndATerminal/openai-compatible_piped_invalid_UTF-8 |
      | TestInstalledKeyLoginUnderPipesAndATerminal/openai-compatible_terminal            |
    And kogen-checks-stall-kogen-builds: the run started no python interpreter from PATH
    And kogen-checks-stall-kogen-builds: the run asked its proxy for no GitHub host

  Scenario: The installed-login test fails when login custody regresses
    When kogen-checks-stall-kogen-builds: the "login regression" run finishes
    Then kogen-checks-stall-kogen-builds: the run failed these Go tests, each output containing its text:
      | test                                                                              | text                                        |
      | TestInstalledKeyLoginUnderPipesAndATerminal/opencode-go_piped_invalid_UTF-8       | opencode-go: key saved (not verified)       |
      | TestInstalledKeyLoginUnderPipesAndATerminal/opencode-go_terminal                  | terminal was not restored                   |
      | TestInstalledKeyLoginUnderPipesAndATerminal/anthropic_piped_invalid_UTF-8         | anthropic: key saved (not verified)         |
      | TestInstalledKeyLoginUnderPipesAndATerminal/anthropic_terminal                    | terminal was not restored                   |
      | TestInstalledKeyLoginUnderPipesAndATerminal/openai-compatible_piped_invalid_UTF-8 | openai-compatible: key saved (not verified) |
      | TestInstalledKeyLoginUnderPipesAndATerminal/openai-compatible_terminal            | terminal was not restored                   |
    And kogen-checks-stall-kogen-builds: the run started no python interpreter from PATH
    And kogen-checks-stall-kogen-builds: the run asked its proxy for no GitHub host

  Scenario: The cli package packages one release for its installed tests
    When kogen-checks-stall-kogen-builds: the "cli shared release" run finishes
    Then kogen-checks-stall-kogen-builds: the run passed these Go tests:
      | test                                   |
      | TestAssemblyUsesThePinnedComponents    |
      | TestUsageLimitPackagingIsolationRound2 |
    And kogen-checks-stall-kogen-builds: the run packaged exactly one release

  Scenario: The buildprogram package packages one release for its installed tests
    When kogen-checks-stall-kogen-builds: the "buildprogram shared release" run finishes
    Then kogen-checks-stall-kogen-builds: the run passed these Go tests:
      | test                           |
      | TestBaselinePerBaseInstalled   |
      | TestBaselinePackagingIsolation |
    And kogen-checks-stall-kogen-builds: the run packaged exactly one release

  Scenario: The shared installed release still exposes a broken resume to the usage-limit test
    When kogen-checks-stall-kogen-builds: the "resume regression" run finishes
    Then kogen-checks-stall-kogen-builds: the run passed these Go tests:
      | test                                |
      | TestAssemblyUsesThePinnedComponents |
    And kogen-checks-stall-kogen-builds: the run failed these Go tests, each output containing its text:
      | test                                | text                        |
      | TestUsageLimitResumeInstalledRound2 | synthetic resume regression |
    And kogen-checks-stall-kogen-builds: the run packaged exactly one release

  Scenario: The shared release still refuses stale packaged source
    When kogen-checks-stall-kogen-builds: the "stale packaging" run finishes
    Then kogen-checks-stall-kogen-builds: the run failed these Go tests, each output containing its text:
      | test                           | text                    |
      | TestBaselinePerBaseInstalled   | packaged source differs |
      | TestBaselinePackagingIsolation | packaged source differs |
    And kogen-checks-stall-kogen-builds: the run packaged exactly one release
