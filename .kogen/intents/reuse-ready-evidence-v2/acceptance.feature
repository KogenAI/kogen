Feature: Reuse unchanged ready evidence
  Scenario: Shape, show unchanged cards and explicitly approve
    When I exercise installed readiness evidence in mode "shape"
    Then the readiness evidence observations are:
      | shapeExecutions      | 1 |
      | shapeMetadata        | true |
      | initialAcceptance    | ["Passing case (passes now)","Failing cases (2 examples) (fails now)"] |
      | firstCardExecutions  | 0 |
      | secondCardExecutions | 0 |
      | cardsIdentical       | true |
      | noApprovalFromCards  | true |
      | mismatchRefused      | true |
      | approvalCode         | 0 |
      | approvalExecutions   | 0 |
      | approvalBindsCard    | true |
      | noBuild              | true |
      | headUnchanged        | true |

  Scenario: Publish a ready refinement without rerunning it on the card
    When I exercise installed readiness evidence in mode "refine"
    Then the readiness evidence observations are:
      | firstCardExecutions     | 0 |
      | secondCardExecutions    | 0 |
      | refineChecked           | true |
      | refinedHashChanged      | true |
      | refinedAcceptance       | ["Passing case (fails now)","Failing cases (2 examples) (fails now)"] |
      | refinedCardExecutions   | 0 |
      | refinedRepeatExecutions | 0 |
      | refinedCardsIdentical   | true |
      | refinementUnapproved    | true |
      | approvalCode            | 0 |
      | approvalExecutions      | 0 |
      | noBuild                 | true |
      | headUnchanged           | true |

  Scenario Outline: Ineligible evidence uses actual fresh checks
    When I exercise installed readiness evidence in mode "<mode>"
    Then the readiness evidence observations are:
      | firstCardExecutions   | 0 |
      | secondCardExecutions  | 0 |
      | freshExecutions       | 1 |
      | freshRepeatExecutions | <repeat> |
      | freshCode             | <code> |
      | freshRepeatCode       | <code> |
      | freshDiagnostic       | true |
      | noFalseCard           | true |
      | stillUnapproved       | true |
      | noBuild               | true |
    Examples:
      | mode      | repeat | code |
      | absent    | 0      | 5    |
      | malformed | 0      | 5    |
      | legacy    | 0      | 5    |
      | baseline  | 1      | 1    |
      | head      | 1      | 1    |
