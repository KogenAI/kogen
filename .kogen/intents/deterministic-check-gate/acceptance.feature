Feature: Deterministic native check orchestration
  Preserve Kogen's safety tests without treating host scheduling as a product defect.
  Historical KOGEN-051 evidence concerns 2180239d, c59fcd4a, 7548b0e4 and 70d5c112,
  not permission to skip a red check or cancel unrelated host workloads.

  Scenario: Delayed readiness and test-owner shutdown have deterministic outcomes
    When I measure native check fixture lifecycle
    Then the native check observations include:
      | delayedMarker | true |
      | missingMarker | true |
      | normal | {"started":true,"cleanupReturned":true,"cliStopped":true,"childStopped":true,"rootRemoved":true,"unrelatedAlive":true} |
      | aborted | {"started":true,"cleanupReturned":true,"cliStopped":true,"childStopped":true,"rootRemoved":true,"unrelatedAlive":true} |

  Scenario: The reported real integration cases retain their guarantees without overlap
    When I run the reported native check regression modules
    Then the native check observations include:
      | exit | 0 |
      | minimumPassed | 28 |
      | failed | 0 |
      | invalid | 0 |
      | skipped | 0 |
      | excluded | 0 |
      | modulePeak | 1 |
      | tests | {"REV-5 interrupted targeted repair reports pending review and changed verification":"passed","clean setup input mutations cannot certify the workspace":"passed","clean checks input mutations cannot certify the workspace":"passed","workspace drift during clean checks cannot certify a pass":"passed","CLI-7 undoes a commit interrupted during postcommit validation":"passed","custody damaged during final readiness cannot publish successful evidence":"passed"} |
