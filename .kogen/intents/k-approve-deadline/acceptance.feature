Feature: Approval attributes time and preserves command diagnostics
  Approval must not share a 120-second execution deadline across successful steps.
  The historical goose-labels-go refusal blamed git add -A -- . with status 143
  after npm ci and go build ./... had consumed the time on a busy Studio Mac.
  The supplied profile (2373 files, 73 MB, mostly vendor/, node_modules ignored)
  measured Git at 0.26-0.39 s, cold Go at 9.7 wall/42 CPU-s, warm Go at 0.66 s,
  and cached npm ci at 0.46 s at 44-74 percent idle, versus under 10 percent idle
  during the failure. These are historical observations, not timing thresholds.
  Deterministic fixtures use only owned sleeping or blocked processes, on macOS
  Apple Silicon and Linux x86-64 glibc; no synthetic shared-host CPU load.

  Scenario: A valid goose-labels-go task exceeds 120 seconds in individually timely steps
    Then the namedfeedback regression "TestApproveDeadlineSplitCLI" runs exactly once and passes in "."

  Scenario: A blocked setup step is refused accurately without retries or orphaned processes
    Then the namedfeedback regression "TestApproveDeadlineHungCLI" runs exactly once and passes in "."

  Scenario: Exit 134 acceptance and exit 23 setup and exit 17 check failures retain stderr
    # Reproduce the missing-report exit 134 with a deterministic exit, not an abort:
    # report_missing: the acceptance command exited 134; its output:
    # kogen: running setup-1: fixture
    # Both command-stdout-diagnostic and command-stderr-diagnostic must survive.
    Then the namedfeedback regression "TestApproveFailureOutputCLI" runs exactly once and passes in "."

  Scenario: Refusals retain truthful per-step durations without becoming ready evidence
    Then the namedfeedback regression "TestApproveFailureEvidenceCLI" runs exactly once and passes in "."

  Scenario: Secret-safe diagnostics preserve existing UTF-8 byte and line bounds
    Then the namedfeedback regression "TestApproveFailureBoundsCLI" runs exactly once and passes in "."
