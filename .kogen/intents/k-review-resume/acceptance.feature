Feature: Resume claude-code Builds whose candidate already passed verification
  The real Build and the real resume entry run over scripted Claude Code sessions and a scripted
  provider in temporary Git fixture projects; no real claude binary, account or network is used.

  Scenario: A claude-code builder's Build stopped in the final verification of an approved review resumes and lands
    When the k-review-resume driver observes "builder-final-verify"
    Then the claude-code builder's Build was stopped by SIGTERM in the final verification of the approved reviewer repair
    And its resume landed the reviewer repair with no new builder session and no new review request

  Scenario: A claude-code reviewer stopped at its round limit after the green pass resumes with one fresh review of the green candidate
    When the k-review-resume driver observes "review-round-limit"
    Then the Build stopped at the claude-code reviewer's round limit with the green pass recorded as the review base
    And its resume discarded the stopped review's edits and landed the green candidate after one fresh claude-code review, with no builder round and no rerun of checks

  Scenario: A claude-code review that failed without edits resumes with one fresh review and discards nothing
    When the k-review-resume driver observes "review-no-edits"
    Then the Build stopped in the claude-code review of the unchanged green candidate with the review base recorded
    And its resume discarded nothing and landed the green candidate after one fresh claude-code review, with no builder round and no rerun of checks

  Scenario: The resumed fresh review still cannot land red work
    When the k-review-resume driver observes "review-resumed-red"
    Then the Build stopped at the claude-code reviewer's round limit with the green pass recorded as the review base
    And the fresh review's red edits stopped at its own round limit without a commit

  Scenario: A blocking claude-code review verdict is not cleared by a fresh session
    When the k-review-resume driver observes "review-blocked"
    Then the resume of the blocked claude-code review was refused, naming the blocker only that reviewer can clear, with nothing changed

  Scenario: A claude-code review checkpoint without a recorded review base states the work to redo
    When the k-review-resume driver observes "review-legacy"
    Then the resume of a checkpoint without a review base was refused, naming the work to redo, with nothing changed

  Scenario: A claude-code builder stopped in its own stage stays refused
    When the k-review-resume driver observes "builder-stage"
    Then the claude-code builder's own stage stays refused with no executor reached and nothing changed
