Feature: Resume an existing Build candidate
  Scenario Outline: Continue the stopped phase and preserve its conversation
    When I qualify native Build resume in mode "<mode>"
    Then the native resume observations are:
      | nativeResume | true |
      | checkpointed | true |
      | landed | true |
      | sameConversation | true |
      | effects | 1 |
      | commitCount | 1 |
      | signed | true |
    Examples:
      | mode |
      | builder |
      | review |
      | interrupt |
      | crash |

  Scenario: Reuse exact green evidence without rebuilding
    When I qualify native Build resume in mode "review"
    Then the native resume observations are:
      | nativeResume | true |
      | noBuilderRestart | true |
      | checkContents | ["baseline", "builder preserved"] |
      | historyPreserved | true |
      | lineageVisible | true |
      | cumulativeUsage | true |
      | secretsAbsent | true |

  Scenario: Verify resumed reviewer repairs and keep feedback with that reviewer
    When I qualify native Build resume in mode "repair"
    Then the native resume observations are:
      | nativeResume | true |
      | landed | true |
      | sameConversation | true |
      | noBuilderRestart | true |
      | repairFeedback | true |
      | checkContents | ["baseline", "builder preserved", "broken", "reviewer repaired"] |
      | finalContents | "reviewer repaired\\n" |
      | commitCount | 1 |
      | signed | true |
      | hooksRan | true |

  Scenario: Never replay an uncertain executed shell side effect
    When I qualify native Build resume in mode "uncertain-tool"
    Then the native resume observations are:
      | nativeResume | true |
      | checkpointed | true |
      | safeBoundary | true |
      | effects | 1 |

  Scenario Outline: Refuse unsafe drift and unusable saved authority
    When I qualify native Build resume in mode "<mode>"
    Then the native resume observations are:
      | nativeResume | true |
      | refused | true |
      | untouched | true |
      | noModelOnRefusal | true |
      | actionable | true |
    Examples:
      | mode |
      | candidate-drift |
      | staged-drift |
      | helper-drift |
      | config-drift |
      | approval-drift |
      | head-drift |
      | other-checkout |
      | malformed |
      | incompatible |
      | missing |
      | legacy |
      | live-lock |

  Scenario: A landed Build cannot commit again
    When I qualify native Build resume in mode "landed"
    Then the native resume observations are:
      | nativeResume | true |
      | landed | true |
      | alreadyLanded | true |
      | untouched | true |
      | noModelOnRefusal | true |
      | commitCount | 1 |
      | signed | true |

  Scenario: Resolve or safely refuse a death inside the ordinary signed commit
    When I qualify native Build resume in mode "uncertain-commit"
    Then the native resume observations are:
      | nativeResume | true |
      | checkpointed | true |
      | safeBoundary | true |
      | commitCount | 1 |
      | signed | true |
      | noModelOnRefusal | true |
