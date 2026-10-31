Feature: kogen/build and kogen/shape finish well inside the go-test check's package timeout

  The go-test check runs `GOFLAGS=-trimpath go test ./...` in cli. Each package's tests run in one test binary
  under Go's default 10-minute timeout, so the check takes as long as its slowest package. With four CPUs' worth of
  Go scheduling (GOMAXPROCS=4) and uncached, kogen/build took 569 to 581 seconds and kogen/shape 421 to 432
  seconds before this change; kogen/build hit the timeout on 30 October.

  Scenario: kogen/build and kogen/shape keep exactly their tests
    When I list the Go tests of package "./build" in cli
    Then the listing has 253 tests whose sorted names hash to "1f911122afd3b89b487e775f354713dc58db9b224591c4ddab829d91f61425d6"
    When I list the Go tests of package "./shape" in cli
    Then the listing has 265 tests whose sorted names hash to "59f479fa16defb326281bb7bb6595beac6d9acabefcb29ba1accf19c93c4d261"
    And the Go test files in "cli/build" have exactly 5 t.Skip calls and the build constraints "//go:build !race"
    And the Go test files in "cli/shape" have exactly 1 t.Skip calls and the build constraints "none"
    And no Go test file under cli outside third_party sets the test timeout, the test parallelism, GOMAXPROCS or GOFLAGS

  Scenario: Kogen itself still flushes its private records to stable storage
    When I run the acceptance's own durability test in package "./durable" in cli
    Then that Go test ran exactly once and passed
    And outside cli/durable only Go test files call "SkipSyncInTests"

  Scenario: The two slowest packages finish well inside the package timeout on four CPUs
    When I run the go-test check's tests uncached in cli with GOMAXPROCS 4, stopping once kogen/build has run serial tests for more than 30 seconds, kogen/shape for more than 120 seconds, or either has run for more than 400 seconds
    Then kogen/build ran its serial tests within 30 seconds
    And kogen/shape ran its serial tests within 120 seconds
    And every package of the run passed
    And kogen/build and kogen/shape each finished within 400 seconds
    And kogen/build passed 884 tests and subtests whose sorted names hash to "b8e14d99d531a00c1f052c91e81404629c29d377257c1297e045627f0f329903" and skipped exactly "TestNamedFeedbackBuilderRepair, TestNamedFeedbackCompatibility"
    And kogen/shape passed 479 tests and subtests whose sorted names hash to "9fb6d6ec233174c194d5dd6a0878e7fbedd358997bb78ef5170e1a5400f1397a" and skipped exactly "none"
