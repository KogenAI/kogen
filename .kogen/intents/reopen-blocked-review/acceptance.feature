Feature: Reopen a blocked independent reviewer by explicit resume
  Background:
    Given the blocked review qualification uses retained executable "/Users/almirsarajcic/Areas/Kogen/studio-work/kogen-dev/failfast-c3ee2a8e/bin/kogen"

  Scenario: Fresh green then explicit same-reviewer clearance
    When I qualify blocked review retry "clear" using "candidate"
    Then the blocked review observations include:
      | reproduced | true |
      | freshComplete | true |
      | sameReviewer | true |
      | newDecision | true |
      | signedLanding | true |
      | custody | true |
      | history | true |
      | lineage | true |
      | usage | true |
      | noBuilderRestart | true |

  Scenario Outline: Unresolved or red retries cannot reuse old approval
    When I qualify blocked review retry "<mode>" using "candidate"
    Then the blocked review observations include:
      | reproduced | true |
      | freshObserved | true |
      | sameReviewer | true |
      | honestResults | true |
      | repeatedSafe | true |
      | noCommit | true |
      | custody | true |
      | history | true |
      | lineage | true |
      | usage | true |
      | noBuilderRestart | true |
    Examples:
      | mode |
      | keep |
      | red |
      | setup-red |

  Scenario: Scoped reviewer repair is externally verified
    When I qualify blocked review retry "repair" using "candidate"
    Then the blocked review observations include:
      | reproduced | true |
      | freshComplete | true |
      | sameReviewer | true |
      | repairVerified | true |
      | signedLanding | true |
      | custody | true |
      | history | true |
      | lineage | true |
      | usage | true |
      | noBuilderRestart | true |

  Scenario Outline: Interrupted retries continue safely with the same owner
    When I qualify blocked review retry "<mode>" using "candidate"
    Then the blocked review observations include:
      | reproduced | true |
      | interruptionReached | true |
      | interruptionSafe | true |
      | freshComplete | true |
      | sameReviewer | true |
      | signedLanding | true |
      | custody | true |
      | history | true |
      | lineage | true |
      | usage | true |
      | noBuilderRestart | true |
    Examples:
      | mode |
      | interrupt-verify |
      | interrupt-review |

  Scenario Outline: Reopen a real retained signed C3 checkpoint
    When I qualify blocked review retry "<mode>" using "retained"
    Then the blocked review observations include:
      | reproduced | true |
      | crossVersion | true |
      | freshObserved | true |
      | sameReviewer | true |
      | honestResults | true |
      | expectedOutcome | true |
      | custody | true |
      | history | true |
      | lineage | true |
      | usage | true |
      | noBuilderRestart | true |
    Examples:
      | mode |
      | clear |
      | red |
