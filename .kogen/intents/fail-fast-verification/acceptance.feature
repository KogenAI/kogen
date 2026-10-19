Feature: Fail fast without weakening final verification
  Scenario Outline: Red candidate passes stop later gates and survive resume honestly
    When I exercise installed fail-fast verification in mode "<mode>"
    Then the fail-fast verification observations are:
      | firstTrace | <trace> |
      | notRun | <not_run> |
      | actualFailure | true |
      | feedbackNamesNotRun | true |
      | logNamesNotRun | true |
      | checkpointNamesNotRun | true |
      | resultNamesNotRun | true |
      | stoppedSummaryNamesNotRun | true |
      | noCommitOnRed | true |
      | indexAndApprovalPreserved | true |
      | unchangedRedRetested | true |
      | repairedCandidateRunsAll | true |
      | signedLanding | true |
      | exactFinalTree | true |
      | oneReviewStage | true |
    Examples:
      | mode | trace | not_run |
      | acceptance | ["setup-1","acceptance-1"] | ["model","z-cheap","a-later"] |
      | custom | ["setup-1","acceptance-1","acceptance-2"] | ["model","z-cheap","a-later"] |
      | model | ["setup-1","acceptance-1","acceptance-2"] | ["z-cheap","a-later"] |
      | project | ["setup-1","acceptance-1","acceptance-2","z-cheap"] | ["a-later"] |
      | setup | ["setup-1"] | ["acceptance","model","z-cheap","a-later"] |

  Scenario: Green reviewer changes run all gates and unchanged approval reuses safely
    When I exercise installed fail-fast verification in mode "reviewer"
    Then the fail-fast verification observations are:
      | firstTrace | ["setup-1","acceptance-1","acceptance-2","z-cheap","a-later"] |
      | notRun | [] |
      | reviewerRedStops | true |
      | sameReviewerGetsFailure | true |
      | repairedCandidateRunsAll | true |
      | unchangedGreenReused | true |
      | signedLanding | true |
      | exactFinalTree | true |
      | oneReviewStage | true |
