Feature: Checkout-local Kogen facts and CLI discovery
  Scenario: Context resolves nested directories and isolates linked worktrees
    When I exercise checkout CLI facts in mode "isolation"
    Then the checkout CLI observations are:
      | supported | true |
      | outside | true |
      | empty | true |
      | nested | true |
      | worktreeIdentity | true |
      | worktreeAbsence | true |
      | dirtyIsNotActive | true |
      | readOnly | true |

  Scenario: Repeated failed attempts remain inspectable and resume has lineage
    When I exercise checkout CLI facts in mode "attempts"
    Then the checkout CLI observations are:
      | supported | true |
      | twoAttempts | true |
      | packageSeparate | true |
      | pagination | true |
      | failureInspection | true |
      | lastStarted | true |
      | rejectedDoesNotReplace | true |
      | resumeLineage | true |
      | originalResults | true |
      | inspectReadOnly | true |
      | receipt | true |

  Scenario: Real phases and verification passes follow a signed Build with reviewer repair
    When I exercise checkout CLI facts in mode "lifecycle"
    Then the checkout CLI observations are:
      | supported | true |
      | phases | ["building","verifying","reviewing","verifying","committing"] |
      | passes | [null,1,null,2,null] |
      | oneReviewerConversation | true |
      | oneSignedCommit | true |
      | idleRetainsLast | true |
      | landedInspection | true |
      | localNotCommitted | true |

  Scenario Outline: Stopped owners are not indefinitely active
    When I exercise checkout CLI facts in mode "<mode>"
    Then the checkout CLI observations are:
      | supported | true |
      | observedActive | true |
      | cleared | true |
      | lastRetained | true |
      | noCommit | true |
      | inspectionStopped | true |
      | receipt | true |
    Examples:
      | mode |
      | interrupt |
      | core-crash |
      | cli-death |

  Scenario: Missing and malformed integration snapshots never invent activity
    When I exercise checkout CLI facts in mode "invalid"
    Then the checkout CLI observations are:
      | supported | true |
      | malformedSafe | true |
      | missingSafe | true |
      | noReconstruction | true |
      | readOnly | true |

  Scenario: Preflight observes useful blockers without executing or changing custody
    When I exercise checkout CLI facts in mode "preflight"
    Then the checkout CLI observations are:
      | supported | true |
      | green | true |
      | scopeHonest | true |
      | dirtyBlocked | true |
      | approvalBlocked | true |
      | conflictBlocked | true |
      | readOnly | true |
      | noCommandsOrProvider | true |

  Scenario: Zsh and bounded fast reads work without the core or historical access
    When I exercise checkout CLI facts in mode "fast" with 20 samples and p95 budget 100 and maximum 500 milliseconds
    Then the checkout CLI observations are:
      | supported | true |
      | completionSyntax | true |
      | intentCandidates | true |
      | resumeCandidates | true |
      | unsupportedExcluded | true |
      | noCoreOrHistory | true |
      | noProvider | true |
      | measuredWithinBudget | true |
      | measurementsRecorded | true |

  Scenario: Structured reads have versioned empty results and predictable errors
    When I exercise checkout CLI facts in mode "errors"
    Then the checkout CLI observations are:
      | supported | true |
      | versioned | true |
      | emptyList | true |
      | unknownRun | true |
      | invalidLimits | true |
      | unavailableProject | true |
      | humanOutput | true |
