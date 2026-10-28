Feature: Required test identities in builder feedback
  Scenario Outline: Named feedback regressions run and pass
    Then the namedfeedback regression "<test>" runs exactly once and passes in "<package>"

    Examples:
      | test                              | package  |
      | TestNamedFeedbackMissingTests     | ./verify |
      | TestNamedFeedbackBuilderRepair    | ./build  |
      | TestNamedFeedbackCompatibility    | ./build  |
      | TestNamedFeedbackShapeGuidance    | ./shape  |
