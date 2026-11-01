Feature: Resume a Build stopped by an executor usage limit
  Keep earlier work and verification history through the existing explicit Resume path.
  No new command, flag, option, timeout, retry or limit change is permitted.

  Scenario: Explicit quota signals are named as usage limits
    Then the namedfeedback regression "TestUsageLimitClassification" runs exactly once and passes in "./executor/claudecode"

  Scenario: Generic api_error and other executor failures retain their current behavior
    Then the namedfeedback regression "TestUsageLimitOtherErrors" runs exactly once and passes in "./executor/claudecode"

  Scenario: Shipped binary resumes round 2 with round 1 and verification pass 1 intact
    # S-FIXTURE-READINESS (Studio), d5a99d2d, d42f6cc, 31 Oct 2026, 12:42:09Z.
    # Historical envelope: subtype success, is_error true, terminal_reason api_error.
    # Synthetic explicit quota signal: assistant error rate_limit.
    # Expected logical rounds: [1,2,2]; final delivery: one verified independently reviewed commit.
    Then the namedfeedback regression "TestUsageLimitResumeInstalledRound2" runs exactly once and passes in "."

  Scenario: Shipped binary resumes round 3 with two rounds and two passes intact
    # K-MODELS-FILE (Kogen), 7e990bed, d42f6cc, 31 Oct 2026, 12:42:00Z.
    # Same historical error envelope; ~87% of the account's 5-hour window is diagnostic only.
    # Expected logical rounds: [1,2,3,3]; fresh conversation is labelled, prior results unchanged.
    Then the namedfeedback regression "TestUsageLimitResumeInstalledRound3" runs exactly once and passes in "."

  Scenario: Limit continuation stays explicit and respects unchanged Build safety
    Then the namedfeedback regression "TestUsageLimitResumeSafety" runs exactly once and passes in "./build"
