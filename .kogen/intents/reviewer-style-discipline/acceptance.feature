Feature: Reviewer style discipline
  Static policy evidence concerns instructions actually emitted to the reviewer,
  not a claim about future model decisions, token savings or performance.

  Scenario: The real reviewer boundary narrows polish without weakening review
    When I capture the installed reviewer style policy
    Then the emitted reviewer instructions contain these paragraphs:
      | paragraph |
      | Delegate mechanically enforceable formatting and style to the existing configured formatters, linters, checks and fixers; preserve their checks and settings. |
      | Review against the approved Intent and explicit existing project conventions, including documented requirements that deterministic tools do not catch. |
      | Repair demonstrated current correctness, safety, scope and meaningful-test defects, and violations of those requirements or conventions. |
      | Do not make preference-only renamings, rearrangements, abstraction changes, speculative refactors or harmless dead-code cleanup merely because code is nearby. Minimal incidental changes needed to repair a demonstrated defect or satisfy configured style or project requirements remain allowed. |
      | Approving unchanged correct code is a successful outcome. There is no edit quota; harmless preferences neither block delivery nor require edits. |
    And the emitted reviewer instructions retain these safeguards:
      | text |
      | For each substantive concern, establish the applicable requirement, a concrete violating path or counterexample, and its observable consequence. |
      | Make scoped repairs yourself and add or update meaningful regression coverage. |
      | Preserve useful tests and every configured check. |
      | Never change the approved baseline, protected files, HEAD or the user's staged work; do not commit. |
      | If final verification fails, you receive the failures in this same conversation |
      | notes never block |
    And none of these reviewer policy owners retain these permissions:
      | owner        | forbidden |
      | instructions | Remove trivial dead code while editing nearby code if useful |
      | instructions | Correct small issues within the review/fix stage when useful |
      | testing      | Remove trivial dead code while editing nearby code if useful |
      | testing      | Correct small issues within the review/fix stage when useful |
      | spec         | Remove trivial dead code while editing nearby code if useful |
      | spec         | Correct small issues within the review/fix stage when useful |
    And the maintained reviewer sections cover these policy terms:
      | owner   | pattern |
      | testing | configured.*(format\|lint\|style) |
      | testing | convention |
      | testing | incidental |
      | testing | unchanged |
      | spec    | configured.*(format\|lint\|style) |
      | spec    | convention |
      | spec    | incidental |
      | spec    | unchanged |
    And the style-policy fixture observations are:
      | observation                    | expected |
      | build status                   | 0 |
      | reviewer requests              | 1 |
      | committed builder contents     | verified edit |
      | reviewer response tool         | submit_review |
