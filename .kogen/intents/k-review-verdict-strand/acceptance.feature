Feature: Preserve green candidates after verdictless review
  Scenario Outline: Incident regressions and safe recovery
    When verdict-strand regression "<test>" runs
    Then verdict-strand regression "<test>" ran and passed
    Examples:
      | test                                    |
      | TestKReviewVerdictStrandReset             |
      | TestKReviewVerdictStrandPinnedResume      |
      | TestKReviewVerdictStrandSafety            |
