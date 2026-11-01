Feature: Approval follows an explicitly approved Git base
  Scenario Outline: Move an unchanged natively shaped package onto parallel landed work
    When I move the approved native Intent using "<mode>"
    Then the approval rebase outcome is "<mode>"
    Examples:
      | mode   |
      | switch |
      | reset  |

  Scenario Outline: Explain why approval cannot be carried onto the new base
    When I move the approved native Intent using "<mode>"
    Then the approval rebase outcome is "<mode>"
    Examples:
      | mode     |
      | pass     |
      | conflict |
      | unsafe   |
