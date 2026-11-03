# LOOP-14/LOOP-15/SET-14: Claude Code can independently serve Shape (including Refine), Build and Review.
# The fake claude is a Node script, not a model, and no live provider or account is used.
Feature: Claude Code serves a complete independent lineup
  Each role is configured on its own; none shares a session with another or falls back to a native
  path. This is deterministic source capability, not live qualification.

  Background:
    Given a clean Kogen home
    And the installed kogen command
    And a Git project from fixture "py-calc"
    And the project is initialized and configured

  @LOOP-14 @LOOP-15 @SET-14 @SHP-1
  Scenario: Claude lineup shapes builds reviews and signs one exact-tree commit
    Given the project config sets "models.shape" to "{executor: claude-code, model: claude-opus-5-5, effort: high}"
    And the project config sets "models.build" to "{executor: claude-code, model: claude-opus-5-5, effort: high}"
    And the project config sets "models.review" to "{executor: claude-code, model: claude-opus-5-5, effort: high}"
    And commit signing is configured with a test SSH key
    And a fake claude with script "lineup-full" is installed as Kogen's Claude Code
    And the environment variable "ANTHROPIC_API_KEY" is "sk-ant-fake-not-a-key"
    And the fake ChatGPT server plays script "build-correct-first-try"
    When the caller runs "kogen intent shape is-even -" with stdin:
      """
      Add calc.is_even(n). Non-integers raise TypeError.
      """
    Then the exit code is 0
    And fake claude role "shape" ran 2 invocations
    And fake claude role "shape" invocation 2 resumed the session of its invocation 1
    When the caller approves "is-even" with the hash from its review card
    Then the exit code is 0
    When the caller runs "kogen intent build is-even"
    Then the exit code is 0
    And HEAD has 1 new commit
    And the new commit is signed
    And the committed contents of "calc.py" contain "isinstance"
    And fake claude role "build" ran 1 invocation
    And fake claude role "review" ran 1 invocation
    And the fake claude roles used 3 distinct sessions
    And no fake claude round had the environment variable "ANTHROPIC_API_KEY"
    And the fake ChatGPT server received 0 requests


  @LOOP-14 @LOOP-15 @SET-14
  Scenario: Explicit mixed role selections never silently reroute a role
    Given the project config sets "models.shape" to "{executor: claude-code, model: claude-opus-5-5, effort: high}"
    And the project config sets "models.build" to "{executor: claude-code, model: claude-opus-5-5, effort: high}"
    And the project config sets "models.review" to "{executor: native, model: gpt-6.1-sol, effort: high}"
    And the caller is signed in to ChatGPT
    And a fake claude with script "lineup-full" is installed as Kogen's Claude Code
    And the fake ChatGPT server plays script "build-correct-first-try"
    When the caller runs "kogen intent shape is-even -" with stdin:
      """
      Add calc.is_even(n). Non-integers raise TypeError.
      """
    Then the exit code is 0
    And fake claude role "shape" ran 2 invocations
    And the fake ChatGPT server received 0 requests
    When the caller approves "is-even" with the hash from its review card
    And the caller runs "kogen intent build is-even"
    Then the exit code is 0
    And HEAD has 1 new commit
    And fake claude role "build" ran 1 invocation
    And fake claude role "review" ran 0 invocations
    And the fake ChatGPT server received 1 request


  @LOOP-14 @LOOP-15 @SET-14
  Scenario: A fresh reviewer receives authority and candidate but no builder transcript or claims
    Given the project config sets "models.build" to "{executor: claude-code, model: claude-opus-5-5, effort: high}"
    And the project config sets "models.review" to "{executor: claude-code, model: claude-opus-5-5, effort: high}"
    And the Intent "is-even" from fixture "is-even" is approved
    And a fake claude with script "lineup-build-review" is installed as Kogen's Claude Code
    And the fake ChatGPT server plays script "build-correct-first-try"
    When the caller runs "kogen intent build is-even"
    Then the exit code is 0
    And HEAD has 1 new commit
    And fake claude role "review" invocation 1 received the argument "--json-schema"
    And fake claude role "review" invocation 1 received the argument "--session-id"
    And fake claude role "review" invocation 1 did not receive any of the arguments "--resume,--continue,--fork-session,--bare"
    And fake claude role "review" invocation 1 received a prompt containing "# Intent"
    And fake claude role "review" invocation 1 received a prompt containing "isinstance"
    And fake claude role "review" invocation 1 received a prompt not containing "BUILDER-CLAIM-MARKER-7f3a"
    And fake claude role "build" invocation 1 received a prompt containing "Do not edit the protected paths"
    And the fake claude roles used 2 distinct sessions
    And the fake ChatGPT server received 0 requests


  @LOOP-14 @LOOP-15 @SET-14
  Scenario: Red reviewer verification returns failures to the same reviewer session
    Given the project config sets "models.build" to "{executor: claude-code, model: claude-opus-5-5, effort: high}"
    And the project config sets "models.review" to "{executor: claude-code, model: claude-opus-5-5, effort: high}"
    And the Intent "is-even" from fixture "is-even" is approved
    And a fake claude with script "lineup-review-repair-red" is installed as Kogen's Claude Code
    And the fake ChatGPT server plays script "build-correct-first-try"
    When the caller runs "kogen intent build is-even"
    Then the exit code is 0
    And HEAD has 1 new commit
    And the committed contents of "calc.py" contain "isinstance"
    And fake claude role "review" ran 3 invocations
    And fake claude role "review" invocation 3 resumed the session of its invocation 1
    And fake claude role "review" invocation 2 resumed the session of its invocation 1
    And fake claude role "review" invocation 2 received a prompt containing "Final verification of your repairs failed"
    And fake claude role "build" ran 1 invocation
    And the fake claude roles used 2 distinct sessions


  @LOOP-14 @LOOP-15 @SET-14
  Scenario: A blocking reviewer verdict stops candidate/review_blocked with edits preserved
    Given the project config sets "models.build" to "{executor: claude-code, model: claude-opus-5-5, effort: high}"
    And the project config sets "models.review" to "{executor: claude-code, model: claude-opus-5-5, effort: high}"
    And the Intent "is-even" from fixture "is-even" is approved
    And a fake claude with script "lineup-review-blocking" is installed as Kogen's Claude Code
    And the fake ChatGPT server plays script "build-correct-first-try"
    When the caller runs "kogen intent build is-even"
    Then the exit code is 1
    And stdout contains "candidate/review_blocked"
    And stdout contains "  edited: calc.py"
    And HEAD is unchanged
    And fake claude role "review" ran 1 invocation
    And fake claude role "build" ran 1 invocation


  @LOOP-14 @LOOP-15 @SET-14
  Scenario: Missing and malformed structured review verdicts stop without a commit
    Given the project config sets "models.build" to "{executor: claude-code, model: claude-opus-5-5, effort: high}"
    And the project config sets "models.review" to "{executor: claude-code, model: claude-opus-5-5, effort: high}"
    And the Intent "is-even" from fixture "is-even" is approved
    And a fake claude with script "lineup-review-missing" is installed as Kogen's Claude Code
    And the fake ChatGPT server plays script "build-correct-first-try"
    When the caller runs "kogen intent build is-even"
    Then the exit code is 1
    And stdout contains "executor/protocol"
    And HEAD is unchanged
    Given the caller discards the edits listed in the last Build output
    And a fake claude with script "lineup-review-malformed" is installed as Kogen's Claude Code
    When the caller runs "kogen intent build is-even"
    Then the exit code is 1
    And stdout contains "candidate/review_invalid"
    And HEAD is unchanged
    And the fake ChatGPT server received 0 requests


  @LOOP-14 @LOOP-15 @SET-14
  Scenario: Missing and malformed structured Shape submissions stop without publication or commit
    Given the project config sets "models.shape" to "{executor: claude-code, model: claude-opus-5-5, effort: high}"
    And a fake claude with script "lineup-shape-missing" is installed as Kogen's Claude Code
    And the fake ChatGPT server plays script "build-correct-first-try"
    When the caller runs "kogen intent shape is-even -" with stdin:
      """
      Add calc.is_even(n). Non-integers raise TypeError.
      """
    Then the exit code is 1
    And stdout contains "executor/protocol"
    And no Intent named is-even exists
    Given a fake claude with script "lineup-shape-malformed" is installed as Kogen's Claude Code
    When the caller runs "kogen intent shape is-even -" with stdin:
      """
      Add calc.is_even(n). Non-integers raise TypeError.
      """
    Then the exit code is 1
    And stdout contains "shape/invalid_output"
    And no Intent named is-even exists
    And HEAD is unchanged
    And the fake ChatGPT server received 0 requests


  @LOOP-14 @LOOP-15 @SET-14
  Scenario: Non-subscription Shape auth stops executor/auth_refused without fallback
    Given the project config sets "models.shape" to "{executor: claude-code, model: claude-opus-5-5, effort: high}"
    And a fake claude with script "lineup-shape-apikey" is installed as Kogen's Claude Code
    And the fake ChatGPT server plays script "build-correct-first-try"
    When the caller runs "kogen intent shape is-even -" with stdin:
      """
      Add calc.is_even(n). Non-integers raise TypeError.
      """
    Then the exit code is 1
    And stdout contains "executor/auth_refused"
    And fake claude role "shape" ran 0 invocations
    And no Intent named is-even exists
    And the fake ChatGPT server received 0 requests


  @LOOP-14 @LOOP-15 @SET-14
  Scenario: Non-subscription Review auth stops executor/auth_refused without fallback
    Given the project config sets "models.build" to "{executor: claude-code, model: claude-opus-5-5, effort: high}"
    And the project config sets "models.review" to "{executor: claude-code, model: claude-opus-5-5, effort: high}"
    And the Intent "is-even" from fixture "is-even" is approved
    And a fake claude with script "lineup-review-apikey" is installed as Kogen's Claude Code
    And the fake ChatGPT server plays script "build-correct-first-try"
    When the caller runs "kogen intent build is-even"
    Then the exit code is 1
    And stdout contains "executor/auth_refused"
    And HEAD is unchanged
    And the fake ChatGPT server received 0 requests


  @LOOP-14 @LOOP-15 @SET-14
  Scenario: Unavailable old and broken role startups stop with executor reasons without fallback
    Given the project config sets "models.shape" to "{executor: claude-code, model: claude-opus-5-5, effort: high}"
    And a fake claude with script "claude-unpinned" is installed as Kogen's Claude Code
    And the fake ChatGPT server plays script "build-correct-first-try"
    When the caller runs "kogen intent shape is-even -" with stdin:
      """
      Add calc.is_even(n). Non-integers raise TypeError.
      """
    Then the exit code is 1
    And stdout contains "executor/unavailable"
    And stdout contains "not the pinned 2.1.312"
    And no Intent named is-even exists
    Given a broken Kogen Claude Code runtime is installed
    When the caller runs "kogen intent shape is-even -" with stdin:
      """
      Add calc.is_even(n). Non-integers raise TypeError.
      """
    Then the exit code is 1
    And stdout contains "executor/unavailable"
    And no Intent named is-even exists
    And the fake ChatGPT server received 0 requests


  @LOOP-14 @LOOP-15 @SET-14
  Scenario: Reviewer protected tool writes are prevented and protected Bash writes are detected
    Given the project config sets "models.build" to "{executor: claude-code, model: claude-opus-5-5, effort: high}"
    And the project config sets "models.review" to "{executor: claude-code, model: claude-opus-5-5, effort: high}"
    And the Intent "is-even" from fixture "is-even" is approved
    And a fake claude with script "lineup-review-protected" is installed as Kogen's Claude Code
    And the fake ChatGPT server plays script "build-correct-first-try"
    When the caller runs "kogen intent build is-even"
    Then the exit code is 1
    And stdout contains "candidate/baseline_changed"
    And stdout contains ".style.cfg"
    And the run log shows an executor hook decision "deny" for the "Write" tool
    And HEAD is unchanged


  @LOOP-14 @LOOP-15 @SET-14 @SHP-11
  Scenario: A Shape or Refine checkout index or HEAD mutation stops before publication
    Given the project config sets "models.shape" to "{executor: claude-code, model: claude-opus-5-5, effort: high}"
    And a fake claude with script "lineup-shape-head" is installed as Kogen's Claude Code
    And the fake ChatGPT server plays script "build-correct-first-try"
    When the caller runs "kogen intent shape is-even -" with stdin:
      """
      Add calc.is_even(n). Non-integers raise TypeError.
      """
    Then the exit code is 1
    And stdout contains "candidate/head_moved"
    And no Intent named is-even exists
    Given the Intent "is-even" from fixture "is-even" is shaped
    And a fake claude with script "lineup-refine-index" is installed as Kogen's Claude Code
    When the caller refines "is-even" with its current baseline and stdin:
      """
      Clarify the existing title only.
      """
    Then the exit code is 1
    And stdout contains "candidate/baseline_changed"
    And the file ".kogen/intents/is-even/intent.md" is unchanged
    And the fake ChatGPT server received 0 requests


  @LOOP-14 @LOOP-15 @SET-14
  Scenario: Shape readiness corrections and exact red acknowledgment stay with the same session
    Given the project config sets "models.shape" to "{executor: claude-code, model: claude-opus-5-5, effort: high}"
    And a fake claude with script "lineup-shape-corrections" is installed as Kogen's Claude Code
    And the fake ChatGPT server plays script "build-correct-first-try"
    When the caller runs "kogen intent shape is-even -" with stdin:
      """
      Add calc.is_even(n). Non-integers raise TypeError.
      """
    Then the exit code is 0
    And fake claude role "shape" ran 3 invocations
    And fake claude role "shape" invocation 2 resumed the session of its invocation 1
    And fake claude role "shape" invocation 3 resumed the session of its invocation 1
    And fake claude role "shape" invocation 2 received a prompt containing "undefined step"
    And fake claude role "shape" invocation 3 received a prompt containing "Readiness observations"
    And the fake claude roles used 1 distinct sessions
    And the file "features/steps/is-even__steps.js" exists
    And the file ".kogen/local/approvals/is-even.json" does not exist
    And the fake ChatGPT server received 0 requests


  @LOOP-14 @LOOP-15 @SET-14
  Scenario: Shape questions retain numbered CLI answers and start a fresh subsequent session
    Given the project config sets "models.shape" to "{executor: claude-code, model: claude-opus-5-5, effort: high}"
    And a fake claude with script "lineup-shape-questions" is installed as Kogen's Claude Code
    And the fake ChatGPT server plays script "build-correct-first-try"
    When the caller runs "kogen intent shape is-even -" with stdin:
      """
      Add calc.is_even(n) and show its result to the user; choose the visual presentation. Non-integers raise TypeError.
      """
    Then the exit code is 5
    And stdout contains "Questions for is-even:"
    And stdout contains "1. How should the result be presented to the user?"
    And stdout contains "a) show a text label (recommended)"
    And no Intent named is-even exists
    When the caller runs "kogen intent shape is-even -" with stdin:
      """
      1: a
      """
    Then the exit code is 0
    And fake claude role "shape" ran 3 invocations
    And fake claude role "shape" invocation 2 started a session of its own
    And fake claude role "shape" invocation 3 resumed the session of its invocation 2
    And fake claude role "shape" invocation 2 received a prompt containing "raise TypeError"
    And the fake claude roles used 2 distinct sessions
    And the fake ChatGPT server received 0 requests


  @LOOP-14 @LOOP-15 @SET-14 @SHP-11
  Scenario: Refine publishes only owned permitted corrections and revokes approval only on success
    Given the project config sets "models.shape" to "{executor: claude-code, model: claude-opus-5-5, effort: high}"
    And the Intent "is-even" from fixture "is-even" is approved
    And a fake claude with script "lineup-refine-title" is installed as Kogen's Claude Code
    And the fake ChatGPT server plays script "build-correct-first-try"
    When the caller refines "is-even" with its current baseline and stdin:
      """
      Clarify the existing title only.
      """
    Then the exit code is 0
    And stdout contains "refined is-even"
    And the file ".kogen/intents/is-even/intent.md" contains "# Clarify the is-even helper"
    And the file ".kogen/intents/is-even/acceptance.feature" is unchanged
    And the file "features/steps/is_even_steps.js" is unchanged
    And the file ".kogen/local/approvals/is-even.json" does not exist
    And fake claude role "shape" ran 2 invocations
    And fake claude role "shape" invocation 2 resumed the session of its invocation 1
    And the fake ChatGPT server received 0 requests


  @LOOP-14 @LOOP-15 @SET-14 @SHP-11
  Scenario: Refused or failed Refine preserves the package approval source HEAD and index
    Given the project config sets "models.shape" to "{executor: claude-code, model: claude-opus-5-5, effort: high}"
    And the Intent "is-even" from fixture "is-even" is approved
    And a fake claude with script "lineup-refine-constraint" is installed as Kogen's Claude Code
    And the fake ChatGPT server plays script "build-correct-first-try"
    When the caller refines "is-even" with its current baseline and stdin:
      """
      Add a new step file to this draft.
      """
    Then the exit code is 1
    And stdout contains "shape/refinement_constraint"
    And the file ".kogen/intents/is-even/intent.md" is unchanged
    And the file ".kogen/intents/is-even/acceptance.feature" is unchanged
    And the file ".kogen/local/approvals/is-even.json" exists
    And HEAD is unchanged
    And nothing is staged
    And the fake ChatGPT server received 0 requests


  @LOOP-14 @LOOP-15 @SET-14
  Scenario: Every hash-bound review source part is delivered completely before approval
    Given the project config sets "models.build" to "{executor: claude-code, model: claude-opus-5-5, effort: high}"
    And the project config sets "models.review" to "{executor: claude-code, model: claude-opus-5-5, effort: high}"
    And the Intent "is-even" from fixture "is-even" is approved
    And a fake claude with script "lineup-review-big" is installed as Kogen's Claude Code
    And the fake ChatGPT server plays script "build-correct-first-try"
    When the caller runs "kogen intent build is-even"
    Then the exit code is 0
    And HEAD has 1 new commit
    And the review material evidence records delivery of the complete source
    And fake claude role "review" invocation 1 received a prompt containing "END-OF-BIG-FILE"
    And the file "big.txt" contains "END-OF-BIG-FILE"


  @LOOP-14 @LOOP-15 @SET-14
  Scenario: Changed custody stops safely and candidate README is not review authority
    Given the project config sets "models.build" to "{executor: claude-code, model: claude-opus-5-5, effort: high}"
    And the project config sets "models.review" to "{executor: claude-code, model: claude-opus-5-5, effort: high}"
    And the Intent "is-even" from fixture "is-even" is approved
    And a fake claude with script "lineup-review-tamper" is installed as Kogen's Claude Code
    And the fake ChatGPT server plays script "build-correct-first-try"
    When the caller runs "kogen intent build is-even"
    Then the exit code is 1
    And stdout contains "candidate/context_custody_invalid"
    And HEAD is unchanged
    Given the caller discards the edits listed in the last Build output
    And a fake claude with script "lineup-review-oversized" is installed as Kogen's Claude Code
    When the caller runs "kogen intent build is-even"
    Then the exit code is 0
    And HEAD has 1 new commit
    And the fake ChatGPT server received 0 requests


  @LOOP-14 @LOOP-15 @SET-14
  Scenario: External round caps preserve the candidate and do not restart another role
    Given the project config sets "models.build" to "{executor: claude-code, model: claude-opus-5-5, effort: high}"
    And the project config sets "models.review" to "{executor: claude-code, model: claude-opus-5-5, effort: high}"
    And the Intent "is-even" from fixture "is-even" is approved
    And a fake claude with script "lineup-review-red-forever" is installed as Kogen's Claude Code
    And the fake ChatGPT server plays script "build-correct-first-try"
    When the caller runs "kogen intent build is-even"
    Then the exit code is 1
    And stdout contains "candidate/executor_round_limit"
    And stdout contains "  edited: calc.py"
    And HEAD is unchanged
    And fake claude role "review" ran 6 invocations
    And fake claude role "build" ran 1 invocation


  @LOOP-14 @LOOP-15 @SET-14
  Scenario: External Review checkpoint resume is refused without mutation or inference
    Given the project config sets "models.build" to "{executor: claude-code, model: claude-opus-5-5, effort: high}"
    And the project config sets "models.review" to "{executor: claude-code, model: claude-opus-5-5, effort: high}"
    And the Intent "is-even" from fixture "is-even" is approved
    And a fake claude with script "lineup-review-blocking" is installed as Kogen's Claude Code
    And the fake ChatGPT server plays script "build-correct-first-try"
    When the caller runs "kogen intent build is-even"
    Then the exit code is 1
    And stdout contains "candidate/review_blocked"
    When the caller runs "kogen intent resume {build_id}"
    Then the exit code is 1
    And stdout contains "candidate/resume_refused"
    And stdout contains "fresh Build"
    And fake claude role "review" ran 1 invocation
    And fake claude role "build" ran 1 invocation
    And HEAD is unchanged


  @LOOP-14 @LOOP-15 @SET-14
  Scenario: Per-role version session model auth rounds and harness usage remain inspectable
    Given the project config sets "models.build" to "{executor: claude-code, model: claude-opus-5-5, effort: high}"
    And the project config sets "models.review" to "{executor: claude-code, model: claude-opus-5-5, effort: high}"
    And the Intent "is-even" from fixture "is-even" is approved
    And a fake claude with script "lineup-build-review" is installed as Kogen's Claude Code
    And the fake ChatGPT server plays script "build-correct-first-try"
    When the caller runs "kogen intent build is-even"
    Then the exit code is 0
    And the run log records 2 executor rounds
    When the caller runs "kogen intent inspect {build_id} --json"
    Then the exit code is 0
    And stdout matches "executors"
    And stdout matches "executors.*review"
    And stdout contains "claude-code 2.1.312 (Claude Code)"


  @LOOP-14 @LOOP-15 @SET-14 @SHP-1
  Scenario: Unsupported probes and images stay explicit and research is not a native record
    Given the project config sets "models.shape" to "{executor: claude-code, model: claude-opus-5-5, effort: high}"
    And a fake claude with script "lineup-shape-research" is installed as Kogen's Claude Code
    And the fake ChatGPT server plays script "build-correct-first-try"
    When the caller runs "kogen intent shape is-even -" with stdin:
      """
      Add calc.is_even(n). Non-integers raise TypeError.
      """
    Then the exit code is 0
    And fake claude role "shape" invocation 1 received a prompt containing "probe, view_image, documentation records, shape_batch"
    And fake claude role "shape" invocation 1 received a prompt containing "harness only"
    And no Kogen documentation record exists for the shape run
    And the fake ChatGPT server received 0 requests

