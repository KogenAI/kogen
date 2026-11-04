Feature: kogen states exactly what it relies on from each Kogen dependency

  Scenario: One consumes suite per Kogen dependency runs in kogen's normal Go test command and passes
    When k-consumes-kogen: I run go test in cli on the consumes suites of
      | kogen-build        |
      | kogen-coordinator  |
      | kogen-executor     |
      | kogen-setup        |
      | kogen-shaping      |
      | kogen-verification |
      | kogen-loop         |
    Then k-consumes-kogen: kogen's normal Go test command in cli lists every one of those suites
    And k-consumes-kogen: every one of those suites passes with at least one test and no failed or skipped test

  Scenario: Every dependency use in kogen's non-test code is covered by that dependency's consumes suite and nothing else is
    When k-consumes-kogen: I take the dependency inventory of kogen's non-test code and its consumes suites
    Then k-consumes-kogen: kogen's non-test code uses exactly these Kogen dependencies
      | kogen-build        |
      | kogen-coordinator  |
      | kogen-executor     |
      | kogen-setup        |
      | kogen-shaping      |
      | kogen-verification |
      | kogen-loop         |
    And k-consumes-kogen: kogen's non-test code uses exactly these identifiers of "kogen-setup"
      | setup.Init             |
      | setup.InitInput        |
      | setup.InitInput.Client |
      | setup.InitInput.Tools  |
    And k-consumes-kogen: kogen's non-test code uses exactly these identifiers of "kogen-verification"
      | verify.Tools            |
      | verify.Tools.Cucumber   |
      | verify.Tools.Node       |
      | verify.Tools.Quint      |
      | verify.ToolsFromInstall |
    And k-consumes-kogen: the consumes directories are exactly the dependencies kogen's non-test code uses
    And k-consumes-kogen: every identifier kogen's non-test code uses from a dependency is referenced in that dependency's consumes suite
    And k-consumes-kogen: every consumes suite README lists every identifier kogen's non-test code uses from its dependency
    And k-consumes-kogen: every consumes suite references only what kogen's non-test code uses from its dependency
    And k-consumes-kogen: every consumes suite imports only the standard library and Kogen dependencies and has no skip, build constraint or host path
