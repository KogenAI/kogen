Feature: Hunk-gated on-demand review
  Scenario Outline: Review honors its evidence contract
    When the revod gate test "<test>" runs
    Then that revod gate test ran and passed

    Examples:
      | test                              |
      | TestKRevodGateHunkCoverage         |
      | TestKRevodGateInvalidBlocker       |
      | TestKRevodGateHunkApproval         |
      | TestKRevodGateMissingRead          |
      | TestKRevodGatePartsUnchanged       |
