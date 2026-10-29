Feature: Unused step definitions warn without refusing publication

  Scenario Outline: Publish with unused definitions
    Then the namedfeedback regression "<test>" runs exactly once and passes in "./shape"
    Examples:
      | test                          |
      | TestUnusedStepWarnShape        |
      | TestUnusedStepWarnReused       |

  Scenario: Preserve all other self-check refusals
    Then the namedfeedback regression "TestUnusedStepWarnShapeRefusals" runs exactly once and passes in "./shape"

  Scenario: Warn in readiness without blocking unused-only candidates
    Then the namedfeedback regression "TestUnusedStepWarnReadiness" runs exactly once and passes in "./verify"

  Scenario: Preserve all other readiness refusals
    Then the namedfeedback regression "TestUnusedStepWarnReadinessRefusals" runs exactly once and passes in "./verify"
