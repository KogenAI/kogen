Feature: Claude Code serves a complete independent lineup
  This is deterministic source capability, not activation at the later 15% threshold.
  Models and effort remain user-configured; no live provider or availability proof is run.
  The named product tests and installed scenarios must contain real behavioral assertions.
  Passing an empty test selection, a stub report, skipped steps or a claimed finish is not proof.

  @lineup-contract
  Scenario: Role selection and the versioned adapter preserve authority and custody
    When I execute the Claude lineup Go contracts:
      | package                | test                              |
      | ./project              | TestClaudeLineupRoleConfiguration |
      | ./executor/claudecode  | TestClaudeLineupRoleProtocol      |
      | ./executor/claudecode  | TestClaudeLineupRoleCustody       |
      | ./executor/conformance | TestClaudeLineupRoleScripts       |
    Then every named Claude lineup Go contract runs and passes once

  @lineup-review
  Scenario: Review remains fresh independent complete bounded and exact-tree verified
    When I execute the Claude lineup Go contracts:
      | package | test                                 |
      | ./build | TestClaudeLineupReviewExactTree       |
      | ./build | TestClaudeLineupReviewMaterialDelivery |
      | ./build | TestClaudeLineupReviewRefusesResume   |
      | ./build | TestClaudeLineupReviewRoundLimit      |
    Then every named Claude lineup Go contract runs and passes once

  @lineup-shape
  Scenario: Shape and Refine use native submission gates without checkout mutation
    When I execute the Claude lineup Go contracts:
      | package | test                                   |
      | ./shape | TestClaudeLineupShapeSubmission         |
      | ./shape | TestClaudeLineupRefinePreservation       |
      | ./shape | TestClaudeLineupShapeCheckoutGuard       |
      | ./shape | TestClaudeLineupUnsupportedCapabilities  |
    Then every named Claude lineup Go contract runs and passes once

  @lineup-native
  Scenario: Omitted and explicit native preserve native bytes and recovery
    When I execute the Claude lineup Go contracts:
      | package   | test                                             |
      | ./project | TestNativeRoleJSONKeepsItsBytes                  |
      | ./build   | TestNativeOpeningInputEqualsTheOpeningMessage    |
      | ./build   | TestNativeFirstRequestCarriesTheOpeningInput     |
      | ./build   | TestNativeCheckpointAndConfigCarryNoExecutorIdentity |
      | ./build   | TestNativeSelectionIgnoresDepsExternal            |
      | ./build   | TestClaudeLineupNativeCompatibility              |
      | ./shape   | TestClaudeLineupNativeCompatibility              |
    Then every named Claude lineup Go contract runs and passes once

  @lineup-installed
  Scenario: The installed CLI proves the complete lineup and its safe negative outcomes
    When I execute the installed Claude lineup specification "spec/features/claude-code-full-lineup.feature"
    Then exactly these installed Claude lineup scenarios execute with every step passing:
      | Claude lineup shapes builds reviews and signs one exact-tree commit |
      | Explicit mixed role selections never silently reroute a role |
      | A fresh reviewer receives authority and candidate but no builder transcript or claims |
      | Red reviewer verification returns failures to the same reviewer session |
      | A blocking reviewer verdict stops candidate/review_blocked with edits preserved |
      | Missing and malformed structured review verdicts stop without a commit |
      | Missing and malformed structured Shape submissions stop without publication or commit |
      | Non-subscription Shape auth stops executor/auth_refused without fallback |
      | Non-subscription Review auth stops executor/auth_refused without fallback |
      | Unavailable old and broken role startups stop with executor reasons without fallback |
      | Reviewer protected tool writes are prevented and protected Bash writes are detected |
      | A Shape or Refine checkout index or HEAD mutation stops before publication |
      | Shape readiness corrections and exact red acknowledgment stay with the same session |
      | Shape questions retain numbered CLI answers and start a fresh subsequent session |
      | Refine publishes only owned permitted corrections and revokes approval only on success |
      | Refused or failed Refine preserves the package approval source HEAD and index |
      | Every hash-bound review source part is delivered completely before approval |
      | Missing changed or oversized review material stops safely without clipping or commit |
      | External round caps preserve the candidate and do not restart another role |
      | External Review checkpoint resume is refused without mutation or inference |
      | Per-role version session model auth rounds and harness usage remain inspectable |
      | Unsupported workers probes and images stay explicit and research is not a native record |
