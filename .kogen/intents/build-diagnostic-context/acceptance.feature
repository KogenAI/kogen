Feature: Optional fresh native Build diagnostic data
  Scenario: Capture exact caller-relative data without changing ordinary input
    When I exercise installed Build diagnostic data in mode "capture"
    Then the Build diagnostic observations are:
      | supported | true |
      | exactCapture | true |
      | privateCapture | true |
      | separateMessage | true |
      | authorityLabel | true |
      | originalMessage | true |
      | stdoutPrivate | true |
      | omittedUnchanged | true |

  Scenario: Reject invalid files and accept adjacent bounded byte sizes
    When I exercise installed Build diagnostic data in mode "files"
    Then the Build diagnostic observations are:
      | supported | true |
      | invalidBeforeEffects | true |
      | validBoundaries | true |

  Scenario: Validate data independently at the native protocol boundary
    When I exercise installed Build diagnostic data in mode "protocol"
    Then the Build diagnostic observations are:
      | invalidBeforeEffects | true |
      | validLabelNotRead | true |

  Scenario: Resume the frozen conversation after replacement and deletion
    When I exercise installed Build diagnostic data in mode "resume"
    Then the Build diagnostic observations are:
      | supported | true |
      | frozenAfterReplacement | true |
      | frozenAfterDeletion | true |
      | versionUnchanged | true |
      | lineage | true |
      | stoppedCustody | true |

  Scenario: Keep diagnostic bypass claims below native guards
    When I exercise installed Build diagnostic data in mode "guards"
    Then the Build diagnostic observations are:
      | supported | true |
      | writeRefused | true |
      | shellStopped | true |
      | noWrongCommit | true |
      | authorityPreserved | true |

  Scenario: Land with current verification and native signing custody
    When I exercise installed Build diagnostic data in mode "land"
    Then the Build diagnostic observations are:
      | supported | true |
      | oneSignedCommit | true |
      | exactTrailer | true |
      | intentCommitted | true |
      | gatesRan | true |
      | captureNotTracked | true |

  Scenario: Reject the flag outside fresh Build
    When I exercise installed Build diagnostic data in mode "unsupported"
    Then the Build diagnostic observations are:
      | allRejected | true |
      | noProviderOrEffects | true |
