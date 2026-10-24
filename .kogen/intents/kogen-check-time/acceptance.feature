Feature: Reduce Kogen check time without reducing proof
  The bounded implementation changes test scheduling, not Kogen behavior or test coverage.
  Measured improvement is a comparable single-host observation, not a performance guarantee.

  Background:
    Given the check-time baseline is revision "687f140700426b3b4ad3e3eae7f1d854762dad31" with 331 CLI files and digest "b1ab0f3faccc277419dda2ec444a4398178c4dbf7a39e84508694edaad4793b8"
    And only these existing tests may gain a leading parallel scheduling annotation:
      | file                         | test                                                            |
      | cli/build/review_test.go      | TestAResumedFittedReviewOfALargerSourcePinsItAndDeliversIt          |
      | cli/build/review_test.go      | TestLargeSourceIsDeliveredAsPinnedPartsAndMustBeReadBeforeApproval |
      | cli/build/resume_test.go      | TestResumeRefusals                                                |
      | cli/build/review_test.go      | TestOneInvalidVerdictIsSentBackAndASecondEndsTheBuild               |
      | cli/build/recover_test.go     | TestRecoveryRefusals                                              |
      | cli/build/context_test.go     | TestAConversationOverTheBudgetIsResetToALocalWorkingWindow         |

  Scenario: Run the bounded tests concurrently without weakening them
    When I run the selected Go tests with race detection and uncached JSON reporting
    Then all selected tests pause and resume concurrently with every reported subtest passing exactly once

  Scenario: Retain comparable whole-check measurements
    Then "docs/check-time-measurements.json" records a faster comparable whole-Go-check observation for these inputs:
      """
      {
        "version": 1,
        "command": ["go", "test", "-race", "-count=1", "-json", "./..."],
        "cwd": "cli",
        "packages": ["kogen", "kogen/agent", "kogen/build", "kogen/git", "kogen/project", "kogen/provider", "kogen/shape", "kogen/sys", "kogen/verify"],
        "environmentKeys": ["CGO_ENABLED", "GOARCH", "GOFLAGS", "GOGC", "GOMEMLIMIT", "GOMAXPROCS", "GOOS", "GORACE", "GOROOT", "GOTOOLCHAIN", "GOWORK", "KOGEN_CUCUMBER", "KOGEN_NODE", "KOGEN_QUINT", "KOGEN_TEST_PYTHON_BIN", "PATH", "TMPDIR"]
      }
      """
