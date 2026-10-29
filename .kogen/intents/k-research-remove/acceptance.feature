Feature: Remove Kogen research settings without changing defaults
  Scenario Outline: Delete the research-only surface
    Then the research removal path "<path>" is absent
    Examples:
      | path |
      | cli/internal/research |
      | cli/loop_knobs_test.go |
      | cli/loop_knobs_fixtures_test.go |

  Scenario: Exercise fixed defaults through the real code
    When I run research removal test "TestResearchRemovalDefaults"
    Then research removal test "TestResearchRemovalDefaults" passes

  Scenario: Retain the existing response budget contract
    When I run research removal test "TestShapeBudgetRoleContract"
    Then research removal test "TestShapeBudgetRoleContract" passes
