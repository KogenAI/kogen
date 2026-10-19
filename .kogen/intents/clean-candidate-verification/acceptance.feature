Feature: Commit-authorizing verification uses clean candidate inputs

  Scenario: An undeclared ignored shell output fails before commit
    When I exercise clean candidate verification in mode "ignored-shell"
    Then the clean candidate observations are:
      | landed                    | false |
      | cleanFailureFeedback      | true  |
      | commitCount               | 0     |
      | indexPreserved            | true  |
      | approvalPreserved         | true  |
      | workspaceArtifactPreserved| true  |
      | reviewStages              | 0     |

  Scenario Outline: Declared commands regenerate ignored output from candidate inputs
    When I exercise clean candidate verification in mode "<mode>"
    Then the clean candidate observations are:
      | landed                    | true  |
      | cleanGenerationObserved   | true  |
      | commitCount               | 1     |
      | freshCloneRuns            | true  |
      | generatedOutputCommitted  | false |
      | candidateInputCommitted   | true  |
      | modelPassed               | true  |
      | hookRan                   | true  |
    Examples:
      | mode         |
      | setup-output |
      | check-output |

  Scenario: Reviewer approval cannot bless an ignored-output dependency
    When I exercise clean candidate verification in mode "reviewer-repair"
    Then the clean candidate observations are:
      | landed                    | true  |
      | cleanFailureFeedback      | true  |
      | sameReviewerRepair        | true  |
      | reviewStages              | 1     |
      | commitCount               | 1     |
      | finalTreeBound            | true  |
      | freshCloneRuns            | true  |
      | workspaceArtifactPreserved| true  |
      | hookRan                   | true  |
