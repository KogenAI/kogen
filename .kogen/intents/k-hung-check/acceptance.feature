Feature: A command that makes no progress is noticed instead of waited on silently
  K-HUNG-CHECK, kogen-main 30 Oct 2026, research cap8 row 3: a native builder shell call
  HEX_OFFLINE=1 make build && npx cucumber-js --strict ... stayed silent for 26 minutes
  (run log gap 22:24 -> 22:50) until an outer cap ended the 45-minute cell, with no
  diagnosis of which command hung. K-CHECKTIME-SHARD Build 7659baca (kogen 5d93641,
  31 Oct 2026) waited 3 hours in verifying pass 3 after the acceptance command of
  2026-10-30T22:44:15Z, with no child process left, until TERM stopped it with
  "stopped in verifying: interrupted". The fixtures are fake commands with controlled
  behaviour; no test sleeps to synchronise with Kogen, and no limit value is raised.

  Scenario: A silent builder shell command is stopped and named, and the Build continues to land
    Then the namedfeedback regression "TestHungShellStoppedBuildLands" runs exactly once and passes in "./build"

  Scenario: A builder shell command that keeps producing output past the bound is not interrupted
    Then the namedfeedback regression "TestProgressingShellNotStopped" runs exactly once and passes in "./build"

  Scenario: Ordinary shell results stay byte-identical to the vendored tool
    Then the namedfeedback regression "TestShellResultBytesUnchanged" runs exactly once and passes in "./build"

  Scenario: A silent independent reviewer shell command is stopped and the review reaches its verdict
    Then the namedfeedback regression "TestReviewHungShellStopped" runs exactly once and passes in "./build"

  Scenario: A verification step with no live process whose result never arrives stops with a message naming it
    Then the namedfeedback regression "TestVerifyEndedCommandNoticed" runs exactly once and passes in "./verify"

  Scenario: A live but silent verification command is waited for and its real result is used
    Then the namedfeedback regression "TestVerifyLiveSilentCommandWaits" runs exactly once and passes in "./verify"
