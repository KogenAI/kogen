Feature: kogen's verdict strand test asserts review outcomes, not kogen-review's prompt layout

  TestKReviewVerdictStrandPinnedResume passes with the kogen-review version cli/go.mod pins, with
  kogen-review main (f041693, the newest main commit kogen's pinned lineup builds) and with a
  stand-in for the layout of kogen-review 7d005ed6, made from that main: the opening's source block
  begins with "# Review task" and carries no pinned-part catalog, and a changes verdict is no longer
  sent back while parts are unread. With the stand-in, the test still catches a review that accepts
  an approval with unread parts, or whose refusal does not name the unread parts.

  Background:
    Given k-consumes-review-parts-unpinned: kogen-review main, the newest main commit kogen's pinned lineup builds, is v0.0.0-20261104085219-f04169324523
    And k-consumes-review-parts-unpinned: the 7d005ed6 layout stand-in is kogen-review main with these edits:
      | file                  | from                                                                                     | to                                                                                                                      | count |
      | review/independent.go | input, err := env.Prepare(pass.Tree, m, role, ReviewerInstructions(), tools, diagnostic) | input, err := env.Prepare(pass.Tree, m, role, ReviewerInstructions(), tools, diagnostic); input = standInOpening(input) | 1     |
      | review/independent.go | if verdict == "changes" && !r.external {                                                 | if verdict == "changes" && !r.external && false {                                                                       | 1     |
    And k-consumes-review-parts-unpinned: the stand-in adds the file review/standin_layout.go:
      """go
      package review

      import "strings"

      // standInOpening is the acceptance stand-in for the layout of kogen-review 7d005ed6: the source
      // block of a fresh review's opening begins with "# Review task" and no longer carries Kogen's
      // pinned-part catalog. Kogen's own custody of the parts is untouched.
      func standInOpening(input []any) []any {
        if len(input) == 0 {
          return input
        }
        first, ok := input[0].(map[string]any)
        if !ok {
          return input
        }
        blocks, ok := first["content"].([]any)
        if !ok || len(blocks) < 2 {
          return input
        }
        block, ok := blocks[1].(map[string]any)
        if !ok {
          return input
        }
        text, _ := block["text"].(string)
        const heading = "# Pinned complete candidate source evidence\n"
        at := strings.Index(text, heading)
        if at < 0 {
          return input
        }
        _, after, _ := strings.Cut(text[at+len(heading):], "\n")
        changed := map[string]any{}
        for k, v := range block {
          changed[k] = v
        }
        changed["text"] = "# Review task\n\nKogen delivers this candidate's pinned source parts; read each one before a verdict.\n\n" + text[:at] + after
        content := append([]any(nil), blocks...)
        content[1] = changed
        opening := map[string]any{}
        for k, v := range first {
          opening[k] = v
        }
        opening["content"] = content
        out := append([]any(nil), input...)
        out[0] = opening
        return out
      }
      """
    And k-consumes-review-parts-unpinned: the faults of the stand-in are:
      | fault                                     | file                  | from                                                                                       | to                                                                                           | count |
      | an approval with unread parts is accepted | review/independent.go | if verdict == "approve" && !r.external {                                                   | if verdict == "approve" && !r.external && false {                                            | 1     |
      | the refusal does not name the unread parts | review/independent.go | "Read all pinned source evidence before approving: %d unread part(s); use read_file on %s", | "Read all pinned source evidence before approving: %d unread part(s); use read_file on %.0s", | 1     |

  Scenario: With the kogen-review version cli/go.mod pins, the strand test passes
    Then k-consumes-review-parts-unpinned: cli/go.mod requires github.com/KogenAI/kogen-review at v0.0.0-20261103161351-e5005fa1daf8 without replacing it
    When k-consumes-review-parts-unpinned: go test runs TestKReviewVerdictStrandPinnedResume in package buildprogram with the committed go.mod
    Then k-consumes-review-parts-unpinned: go test reported TestKReviewVerdictStrandPinnedResume passing

  Scenario: Against kogen-review main, the strand test passes
    When k-consumes-review-parts-unpinned: go test runs TestKReviewVerdictStrandPinnedResume in package buildprogram against kogen-review main
    Then k-consumes-review-parts-unpinned: go test reported TestKReviewVerdictStrandPinnedResume passing

  Scenario: Against the 7d005ed6 layout stand-in, the strand test passes
    When k-consumes-review-parts-unpinned: go test runs TestKReviewVerdictStrandPinnedResume in package buildprogram against the stand-in
    Then k-consumes-review-parts-unpinned: go test reported TestKReviewVerdictStrandPinnedResume passing

  Scenario Outline: With the stand-in's layout, the strand test still catches a review where <fault>
    When k-consumes-review-parts-unpinned: go test runs TestKReviewVerdictStrandPinnedResume in package buildprogram against the stand-in
    Then k-consumes-review-parts-unpinned: go test reported TestKReviewVerdictStrandPinnedResume passing
    When k-consumes-review-parts-unpinned: go test runs TestKReviewVerdictStrandPinnedResume in package buildprogram against the stand-in with the fault "<fault>"
    Then k-consumes-review-parts-unpinned: go test reported TestKReviewVerdictStrandPinnedResume failing

    Examples:
      | fault                                      |
      | an approval with unread parts is accepted  |
      | the refusal does not name the unread parts |
