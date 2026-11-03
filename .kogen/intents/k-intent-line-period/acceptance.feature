Feature: Tests and Decisions lines may end with one sentence period
  A Tests line or a Decisions item that is valid apart from one period directly after its closing
  parenthesis passes the Intent check, and so does the same line without the period. Every other
  malformed line fails exactly as before, with the same problem text.

  Scenario: The specification states the accepted trailing period
    Then the k-line-period file "spec/prose/02-shaping.md" contains:
      """
      A `## Tests` line or a `## Decisions` item may end with one period directly after its closing parenthesis; Kogen accepts it with or without that period and keeps the line as written.
      """
