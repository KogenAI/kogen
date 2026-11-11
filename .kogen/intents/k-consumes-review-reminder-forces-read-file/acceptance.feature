Feature: kogen's verdict strand test accepts a forced read_file reminder while pinned parts are unread

  This feature checks TestKReviewVerdictStrandPinnedResume in cli/buildprogram against kogen-review
  before and after its review-reminder-reads-unread-parts change. After a turn with no tool call,
  the changed reviewer forces read_file while pinned parts are still unread, and forces
  submit_review only once every pinned part has been read. The test accepts either forced reminder,
  counts a forced read_file only while the review has unread pinned parts, and keeps its other
  assertions. The read_file stand-in is the pinned kogen-review with that tool choice; its fault
  forces read_file on every reminder, also after every pinned part has been delivered.

  Background:
    Given k-consumes-review-reminder-forces-read-file: cli/go.mod requires github.com/KogenAI/kogen-review at v0.0.0-20261108105409-1a55cd0ae6ca without replacing it
    And k-consumes-review-reminder-forces-read-file: the kogen-review stand-ins are the pinned kogen-review with these edits:
      | stand_in         | file                  | from                     | to                                                                                                                                       | count |
      | read_file        | review/independent.go | force = SubmitReviewTool | force = SubmitReviewTool; if unread, err := r.unread(r.sess.Input); err == nil && len(unread) > 0 && !overBudget { force = "read_file" } | 1     |
      | read_file always | review/independent.go | force = SubmitReviewTool | force = "read_file"                                                                                                                      | 1     |

  Scenario: The strand test passes with kogen-review before and after the reminder forces read_file
    Then k-consumes-review-reminder-forces-read-file: TestKReviewVerdictStrandPinnedResume passes against the stand-in "read_file"
    And k-consumes-review-reminder-forces-read-file: TestKReviewVerdictStrandPinnedResume passes with the committed go.mod

  Scenario: A forced read_file counts as the reminder only while the review has unread pinned parts
    Then k-consumes-review-reminder-forces-read-file: TestKReviewVerdictStrandPinnedResume fails against the stand-in "read_file always" reporting:
      """
      review 2's conversation has no forced reminder: no request names submit_review, or read_file while pinned parts are unread, as its tool choice
      """
