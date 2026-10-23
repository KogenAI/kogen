Feature: Native Build unblocking without weaker authority
  Scenario: Preserve a blocked candidate and complete a freshly approved Build
    When I exercise native unblocking in mode "recover"
    Then the unblocking observations are:
      | recovery exit | 0 |
      | exact private archive | true |
      | only production cleared | true |
      | original run unchanged | true |
      | no recovery inference | true |
      | repeat refused | true |
      | refinement exit | 0 |
      | fresh approval required | true |
      | fresh build exit | 0 |
      | one signed commit | true |
      | independent changed-tree verification | true |
      | landed approval consumed | true |
      | handoff used not imported | true |

  Scenario Outline: Refuse unsafe recovery without touching the checkout
    When I exercise native unblocking in mode "<mode>"
    Then the unblocking observations are:
      | recovery exit | 1 |
      | native recovery refusal | true |
      | unchanged checkout | true |
      | no recovery inference | true |
      | no archive published | true |
    Examples:
      | mode |
      | candidate-drift |
      | index-drift |
      | approval-drift |
      | head-drift |
      | baseline-drift |
      | missing-checkpoint |
      | legacy-checkpoint |
      | existing-output |
      | inside-output |
      | non-blocker |

  Scenario: Observer polarity cannot claim two successful controls discriminate
    When I exercise native unblocking in mode "polarity"
    Then the unblocking observations are:
      | bad-zero refused | true |
      | good-nonzero refused | true |
      | rejected capability supported | true |
      | corrected observer ready | true |

  Scenario: Deeper fixture expectations are exercised despite missing-feature red
    When I exercise native unblocking in mode "masked-controls"
    Then every unblocking control is independently qualified:
      | retry cursor beyond script |
      | full Refine tool output |
      | landed approval absence |
      | comparison tokenization |
      | outer input scope |
      | generated protocol extension |

  Scenario: Native Shape and Refine receive risk-targeted control guidance
    When I exercise native unblocking in mode "guidance"
    Then the unblocking observations are:
      | Shape guidance | true |
      | Refine guidance | true |

  Scenario Outline: Environmental stops do not become automatic contract recovery
    When I exercise native unblocking in mode "<mode>"
    Then the unblocking observations are:
      | honest stop | true |
      | unchanged checkout | true |
      | native recovery refusal | true |
      | no recovery inference | true |
      | unrelated process alive | true |
    Examples:
      | mode |
      | startup-stop |
      | login-stop |
      | provider-stop |
