Feature: Rebuild an already-satisfied Intent
  Scenario: Already present work completes successfully after fresh verification and review
    Then the namedfeedback regression "TestSatisfiedRebuildAlreadyPresent" runs exactly once and passes in "./build"

  Scenario: Already present work preserves an unrelated staged Intent
    Then the namedfeedback regression "TestSatisfiedRebuildPreservesStagedIntent" runs exactly once and passes in "./build"

  Scenario: Nonempty commits remain normal
    Then the namedfeedback regression "TestOtherIntentsStayOutOfTheCandidateAndTheCommit" runs exactly once and passes in "./build"

  Scenario: A real commit hook failure remains an error
    Then the namedfeedback regression "TestACommitHookThatRejectsLeavesEditsAndRestoresTheStagedIntentIndex" runs exactly once and passes in "./build"
