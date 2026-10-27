Feature: Incomplete source delivery is not a changes blocker
  A reviewer that answers changes while pinned source parts are unread is sent back to read.

  Scenario: A changes verdict while parts are unread gets feedback and the reviewer then approves
    When the k11 reviewer plays "changes,read-all-approve"
    Then the k11 build landed after at least 1 unread-parts feedback with a falling count

  Scenario: The unread problem is not counted while the unread count falls
    When the k11 reviewer plays "changes,read-last,changes,read-all-approve"
    Then the k11 build landed after at least 2 unread-parts feedbacks with a falling count

  Scenario: A real blocking finding after every part was read still blocks the review
    When the k11 reviewer plays "read-all-changes"
    Then the k11 build stopped as review_blocked on the real finding

  Scenario: A reviewer that keeps answering changes without reading is still stopped
    When the k11 reviewer plays "changes-forever"
    Then the k11 build ended without a commit and without looping

  Scenario: The K1 re-review follow-ups are in place
    Then the k11 review_external.go and resume subtest follow-ups are in place
    And the go test "./build" named "TestClaudeLineupReviewRefusesResume/native builder checkpoint" passes
    And the go package "./shape" has a passing test whose name starts with "TestSumUsage"
