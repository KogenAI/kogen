Feature: Native shaping and refinement speed with unchanged authority
  Background:
    Given the faster shaping trial configuration:
      """
      shape_workers:
        enabled: true
        read: {model: gpt-6-luna, effort: medium}
        probe: {model: gpt-6-luna, effort: medium}
        draft: {model: gpt-6-luna, effort: max}
      """

  Scenario: Independently qualify the native refinement helper without worker support
    When I exercise the native shaping speed boundary in mode "smoke"
    Then the faster shaping observations are:
      | code              | 1    |
      | originalRuns      | 1    |
      | originalModelRuns | 2    |
      | providerCalls     | 1    |
      | rootUnchanged     | true |
      | rawIndexUnchanged | true |
      | approvalUnchanged | true |
      | realObservations  | true |
      | serverErrors      | []   |

  Scenario Outline: Selective context retains exact authority and allows focused probes
    When I exercise the native shaping speed boundary in mode "<mode>"
    Then the faster shaping observations are:
      | code                 | 0    |
      | indexedRetrievable   | true |
      | bulkOmitted          | true |
      | exactReadReturned    | true |
      | focusedProbeRan      | true |
      | focusedGuidance      | true |
      | authorityRetained    | true |
      | observationsReturned | true |
      | contextMeasured      | true |
      | candidateRuns        | 1    |
      | candidateModelRuns   | 2    |
      | rawIndexUnchanged    | true |
      | unapproved           | true |
      | serverErrors         | []   |
    Examples:
      | mode           |
      | shape-context  |
      | refine-context |

  Scenario: Valid retained evidence skips original setup/readiness with nonempty setup, never a changed candidate
    When I exercise the native shaping speed boundary in mode "reuse"
    Then the faster shaping observations are:
      | code                 | 0    |
      | originalRuns         | 0    |
      | originalModelRuns    | 0    |
      | candidateRuns        | 1    |
      | candidateModelRuns   | 2    |
      | originalHit          | true |
      | truthfulReuseReceipt | true |
      | originalSetupRuns    | 0    |
      | candidateSetupRuns   | 1    |
      | observationsReturned | true |
      | realObservations     | true |
      | rootOnlyCorrection   | true |
      | rawIndexUnchanged    | true |
      | unapproved           | true |
      | serverErrors         | []   |

  Scenario Outline: Unusable original evidence follows normal scratch checking and refusal preserves authority
    When I exercise the native shaping speed boundary in mode "<mode>"
    Then the faster shaping observations are:
      | code              | 1    |
      | originalRuns      | 1    |
      | originalModelRuns | 2    |
      | originalMiss      | true |
      | providerCalls     | 1    |
      | rootUnchanged     | true |
      | rawIndexUnchanged | true |
      | approvalUnchanged | true |
      | realObservations  | true |
      | serverErrors      | []   |
    Examples:
      | mode               |
      | missing            |
      | stale              |
      | malformed          |
      | changed-head       |
      | changed-protection |

  Scenario: Changed candidate setup detects environment drift despite retained original evidence
    When I exercise the native shaping speed boundary in mode "environment-failure"
    Then the faster shaping observations are:
      | code                    | 1    |
      | originalHit             | true |
      | originalRuns            | 0    |
      | originalModelRuns       | 0    |
      | originalSetupRuns       | 0    |
      | candidateSetupRuns      | 1    |
      | candidateRuns           | 0    |
      | candidateFailureReturned| true |
      | rootUnchanged           | true |
      | rawIndexUnchanged       | true |
      | approvalUnchanged       | true |
      | realObservations        | true |
      | serverErrors            | []   |

  Scenario Outline: Preserve the sequential path and measure its baseline
    When I exercise native shaping delegation in mode "<mode>"
    Then the faster shaping observations are:
      | code               | 5         |
      | workerCalls        | 0         |
      | mainHasBatch       | <tool>    |
      | mainModel          | gpt-6.1-sol/high |
      | noIntent           | true      |
      | protectedUnchanged | true      |
      | headUnchanged      | true      |
      | indexUnchanged     | true      |
      | phaseDurations     | true      |
      | serverErrors       | []        |
    Examples:
      | mode       | tool  |
      | opt-out    | false |
      | disabled   | false |
      | sequential | true  |

  Scenario Outline: Require explicit complete worker roles before any provider call
    When I exercise native shaping delegation in mode "<mode>"
    Then the faster shaping observations are:
      | code        | 3    |
      | allCalls    | 0    |
      | workerCalls | 0    |
      | noIntent    | true |
    And the faster shaping diagnostic contains "environment/project_config_invalid:"
    Examples:
      | mode           |
      | missing-role   |
      | missing-effort |

  Scenario Outline: Refuse incomplete or conflicting dispatch before worker calls
    When I exercise native shaping delegation in mode "<mode>"
    Then the faster shaping observations are:
      | code               | 5    |
      | workerCalls        | 0    |
      | refused            | true |
      | refusalHasReason   | true |
      | noIntent           | true |
      | readinessRuns      | 0    |
      | protectedUnchanged | true |
      | indexUnchanged     | true |
      | serverErrors       | []   |
    Examples:
      | mode             |
      | missing-brief    |
      | missing-boundary |
      | stale-revision   |
      | stale-tree       |
      | overlap          |
      | alias-overlap    |
      | empty            |
      | four             |

  Scenario Outline: Integrate scoped drafts through one unchanged normal readiness gate
    When I exercise native shaping delegation in mode "<mode>"
    Then the faster shaping observations are:
      | code                    | 0            |
      | mainHasBatch            | true         |
      | overlap                 | <overlap>    |
      | configuredModels        | <models>     |
      | roleProvenance          | true         |
      | noLiveDraft             | true         |
      | mainSubmitted           | true         |
      | integratedDraft         | true         |
      | readinessRuns           | 1            |
      | observationsReturned    | true         |
      | phaseDurations          | true         |
      | unionDurations          | true         |
      | headUnchanged           | true         |
      | indexUnchanged          | true         |
      | protectedUnchanged      | true         |
      | scratchIsolated         | true         |
      | unapproved              | true         |
      | cardStable              | true         |
      | cardReuse               | true         |
      | cardUnapproved          | true         |
      | mismatchRefused         | true         |
      | explicitApproval        | true         |
      | approvalReuse           | true         |
      | changedBaselineRefused  | true         |
      | noImplicitAuthority     | true         |
      | serverErrors            | []           |
    Examples:
      | mode       | overlap | models                                |
      | single     | false   | ["gpt-6-luna/max"]                    |
      | two-drafts | true    | ["gpt-6-luna/max"]                    |
      | three      | true    | ["gpt-6-luna/max","gpt-6-luna/medium"] |

  Scenario: Worker allowlists reject forged authority and preserve scratch isolation
    When I exercise native shaping delegation in mode "restrictions"
    Then the faster shaping observations are:
      | code               | 0    |
      | workerCapabilities | {"read":["list_files","read_file","search_text","worker_result"],"probe":["list_files","probe","read_file","search_text","worker_result"],"draft":["worker_result"]} |
      | forgedCallsRefused | true |
      | noLiveDraft        | true |
      | mainSubmitted      | true |
      | readinessRuns      | 1    |
      | protectedUnchanged | true |
      | scratchIsolated    | true |
      | unapproved         | true |
      | serverErrors       | []   |

  Scenario: Refuse unauthorized returned draft files
    When I exercise native shaping delegation in mode "unowned"
    Then the faster shaping observations are:
      | code                 | 5      |
      | batchStatus          | failed |
      | unauthorizedRejected | true   |
      | mainSubmitted        | false  |
      | noIntent             | true   |
      | protectedUnchanged   | true   |
      | readinessRuns        | 0      |
      | unapproved           | true   |
      | serverErrors         | []     |

  Scenario: Stop a worker at the provider call bound without replay
    When I exercise native shaping delegation in mode "limits"
    Then the faster shaping observations are:
      | code          | 5      |
      | batchStatus   | failed |
      | limitCalls    | 6      |
      | mainSubmitted | false  |
      | noIntent      | true   |
      | readinessRuns | 0      |
      | serverErrors  | []     |

  Scenario: Preserve completed usage and sibling evidence after a worker transport failure
    When I exercise native shaping delegation in mode "failure"
    Then the faster shaping observations are:
      | code                      | 5       |
      | batchStatus               | partial |
      | failureTruthful           | true    |
      | probeCalls                | 2       |
      | knownUsageRetained         | true    |
      | completedEvidenceRetained | true    |
      | mainSubmitted             | false   |
      | noLiveDraft               | true    |
      | noIntent                  | true    |
      | readinessRuns             | 0       |
      | headUnchanged             | true    |
      | indexUnchanged            | true    |
      | protectedUnchanged        | true    |
      | unapproved                | true    |
      | serverErrors              | []      |

  Scenario: Represent unavailable worker token and cache usage as unknown
    When I exercise native shaping delegation in mode "unknown-usage"
    Then the faster shaping observations are:
      | code           | 0    |
      | unknownUsage   | true |
      | roleProvenance | true |
      | readinessRuns  | 1    |
      | serverErrors   | []   |

  Scenario: Cancel the batch after one job completed without losing its evidence
    When I exercise native shaping delegation in mode "cancel"
    Then the faster shaping observations are:
      | code                      | 130   |
      | completedEvidenceRetained | true  |
      | cancelledEvidence         | true  |
      | workerResponsesClosed     | true  |
      | mainSubmitted             | false |
      | noIntent                  | true  |
      | readinessRuns             | 0     |
      | headUnchanged             | true  |
      | indexUnchanged            | true  |
      | protectedUnchanged        | true  |
      | unapproved                | true  |
      | serverErrors              | []    |

  Scenario: Real bridge owner serializes probes while independent provider jobs overlap
    When I exercise native shaping delegation in mode "owner"
    Then the faster shaping observations are:
      | code                | 0    |
      | overlap             | true |
      | ownerProbeCompleted | true |
      | probesSerialized    | true |
      | independentHTTPHeld | true |
      | readinessRuns       | 1    |
      | protectedUnchanged  | true |
      | indexUnchanged      | true |
      | serverErrors        | []   |

  Scenario: Interrupt reaches an owner-executed probe and outstanding HTTP job
    When I exercise native shaping delegation in mode "owner-cancel"
    Then the faster shaping observations are:
      | code                      | 130   |
      | completedEvidenceRetained | true  |
      | cancelledEvidence         | true  |
      | workerResponsesClosed     | true  |
      | ownerProbeStarted         | true  |
      | probeDescendantStopped    | true  |
      | probeScratchRemoved       | true  |
      | mainSubmitted             | false |
      | noIntent                  | true  |
      | readinessRuns             | 0     |
      | headUnchanged             | true  |
      | indexUnchanged            | true  |
      | protectedUnchanged        | true  |
      | serverErrors              | []    |
