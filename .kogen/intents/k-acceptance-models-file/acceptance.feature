Feature: kogen's acceptance follows kogen-coordinator's model lineup files
  Since kogen-coordinator 4826fb1 the approval baseline includes the team model lineup
  .kogen/models.yaml. These scenarios run scenarios of kogen's own acceptance suite
  (test/acceptance) against the release archive built from this checkout, and against that
  release whose kogen passes its standard output through a wrapper that can drop the lines
  containing given texts.

  Background:
    Given k-acceptance-models-file: the release archive built from this checkout

  Scenario: kogen pins kogen-coordinator at or after 4826fb1 and the release carries it
    Then k-acceptance-models-file: cli/go.mod requires "github.com/KogenAI/kogen-coordinator" at a pseudo-version dated at or after "20261103201314"
    And k-acceptance-models-file: the release's kogen carries the "github.com/KogenAI/kogen-coordinator" version that cli/go.mod requires

  Scenario: The three stop scenarios pass with the lineup-aware coordinator
    When k-acceptance-models-file: kogen's acceptance suite runs these scenarios against the release:
      | feature                             | scenario                                                                  |
      | 02-shaping.feature                  | An unsupported correction preserves the ready draft                       |
      | 03-approval-and-build-start.feature | A not-ready Intent has no card and cannot be approved                     |
      | claude-code-full-lineup.feature     | A Shape or Refine checkout index or HEAD mutation stops before publication |
    Then k-acceptance-models-file: every listed scenario passed

  Scenario: Each scenario fails when its stop is not reported
    Given k-acceptance-models-file: the release's kogen drops from its standard output every line containing one of:
      """
      shape/refinement_constraint
      intent/not_ready
      candidate/baseline_changed
      """
    When k-acceptance-models-file: kogen's acceptance suite runs these scenarios against the release:
      | feature                             | scenario                                                                  |
      | 02-shaping.feature                  | An unsupported correction preserves the ready draft                       |
      | 03-approval-and-build-start.feature | A not-ready Intent has no card and cannot be approved                     |
      | claude-code-full-lineup.feature     | A Shape or Refine checkout index or HEAD mutation stops before publication |
    Then k-acceptance-models-file: the release's kogen dropped a line containing "shape/refinement_constraint"
    And k-acceptance-models-file: the release's kogen dropped a line containing "intent/not_ready"
    And k-acceptance-models-file: the release's kogen dropped a line containing "candidate/baseline_changed"
    And k-acceptance-models-file: the listed scenarios failed at these steps:
      | scenario                                                                  | step                                                               | error                                |
      | An unsupported correction preserves the ready draft                       | stdout contains "shape/refinement_constraint"                      | stdout did not contain expected text |
      | A not-ready Intent has no card and cannot be approved                     | stdout contains "intent/not_ready: the Intent is not ready to build" | stdout did not contain expected text |
      | A Shape or Refine checkout index or HEAD mutation stops before publication | stdout contains "candidate/baseline_changed"                       | stdout did not contain expected text |

  Scenario: The same wrapper passing everything through keeps the scenarios green
    Given k-acceptance-models-file: the release's kogen passes its standard output through unchanged
    When k-acceptance-models-file: kogen's acceptance suite runs these scenarios against the release:
      | feature                             | scenario                                                                  |
      | 02-shaping.feature                  | An unsupported correction preserves the ready draft                       |
      | 03-approval-and-build-start.feature | A not-ready Intent has no card and cannot be approved                     |
      | claude-code-full-lineup.feature     | A Shape or Refine checkout index or HEAD mutation stops before publication |
    Then k-acceptance-models-file: the release's kogen ran through the wrapper
    And k-acceptance-models-file: every listed scenario passed

  Scenario: The specification names the team lineup file in the acceptance baseline
    Then k-acceptance-models-file: the "VER-1" line of "spec/prose/05-verifying.md" contains:
      """
      The baseline is: everything in `.kogen/intents/<slug>/`, every path in its `Acceptance:` list, `.kogen/project.yaml`, the team model lineup `.kogen/models.yaml` right after it (even when that file does not exist), and every file matching `protect`. The machine override `.kogen/local/models.yaml` is in the baseline only when a `protect` pattern matches it.
      """
