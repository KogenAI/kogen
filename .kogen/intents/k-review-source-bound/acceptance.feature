Feature: Review fits the reviewer's context, source included

  The Claude Code reviewer's complete first prompt (its review constraints, the authority and
  the candidate source) is measured against the unchanged inclusive 524288-byte input ceiling
  before it is sent. A fitting prompt is the unchanged single inline review. A larger one is
  reviewed in ordered parts of the exact source, each in its own fresh session whose prompt fits.
  Mandatory material that leaves no room stops before anything is sent, and Claude Code's
  "Prompt is too long" refusal is a context result, never an ordinary executor failure.

  Scenario: A change whose review prompt fits is reviewed inline in one session, as before
    When the krsb Build runs the fixture "small"
    Then the krsb Build landed one commit after an approving review
    And the krsb review used one session whose prompt carried the complete authority and source inline within 524288 bytes

  Scenario: Six added files of 117,300 bytes (one 723,764-byte prompt today) are reviewed in two parts
    When the krsb Build runs the fixture "six"
    Then the krsb Build landed one commit after an approving review
    And the krsb review was cut into 2 parts, each sent to its own fresh session within 524288 bytes with the complete authority
    And the krsb parts carry the exact review source in order without clipping
    And no krsb changed file that fits one part was split across parts

  Scenario: The K-MODELS-FILE reproduction, 80 changed files and about 2.8 MB of source, is reviewed in parts instead of one refused prompt
    When the krsb Build runs the fixture "repro"
    Then the krsb Build landed one commit after an approving review
    And the krsb review was cut into at least 6 parts, each sent to its own fresh session within 524288 bytes with the complete authority
    And the krsb parts carry the exact review source in order without clipping
    And no krsb changed file that fits one part was split across parts

  Scenario: One added file larger than a part is split at line boundaries
    When the krsb Build runs the fixture "large"
    Then the krsb Build landed one commit after an approving review
    And the krsb review was cut into 3 parts, each sent to its own fresh session within 524288 bytes with the complete authority
    And the krsb parts carry the exact review source in order without clipping
    And every krsb part that ends inside a file ends at a line boundary

  Scenario Outline: A blocking verdict on any part stops the Build with nothing committed
    When the krsb Build runs the fixture "<fixture>"
    Then the krsb Build stopped with "candidate/review_blocked" and "review: big-1.txt:1: part blocker", committed nothing and kept the candidate files
    And the krsb review was in parts and stopped as review_blocked after <sessions> review sessions

    Examples:
      | fixture     | sessions |
      | part1-block | 1        |
      | part2-block | 2        |

  Scenario: Mandatory review material that leaves no room for source stops before any review is sent
    When the krsb Build runs the fixture "authority"
    Then the krsb Build stopped before sending any review, naming the mandatory review material and the 524288-byte ceiling

  Scenario: Claude Code's "Prompt is too long" refusal is a context result, not an ordinary executor failure
    When the krsb Build runs the fixture "refusal"
    Then the krsb Build reported the refusal as a context result naming blocking_limit, never as an executor failure
