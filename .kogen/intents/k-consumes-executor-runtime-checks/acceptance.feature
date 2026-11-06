Feature: TestClaudeChecks passes with and without kogen-executor's runtime checks

  Scenario: TestClaudeChecks passes against the pinned kogen-executor and against its runtime checks, and still tells versions and sign-ins apart
    When k-consumes-executor-runtime-checks: TestClaudeChecks runs against the pinned kogen-executor and against copies with the runtime checks
    Then k-consumes-executor-runtime-checks: every TestClaudeChecks subtest passes against the pinned kogen-executor
    And k-consumes-executor-runtime-checks: every TestClaudeChecks subtest passes against the kogen-executor with the runtime checks
    And k-consumes-executor-runtime-checks: TestClaudeChecks fails only in the version subtest against runtime checks that accept every version
    And k-consumes-executor-runtime-checks: TestClaudeChecks fails only in the two sign-in subtests against runtime checks that report every runtime signed in
