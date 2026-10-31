Feature: Shape only evidence that fits approval limits
  Scenario Outline: Native shaping enforces approval command budgets
    Then focused Shape budget regression "<test>" passes

    Examples:
      | test                                    |
      | TestShapeFeasibilityFitsLimit            |
      | TestShapeTimelyEvidenceFitsLimit         |
      | TestShapeAcceptanceFitsLimit             |
      | TestShapeTimelyAcceptanceFitsLimit       |
