Feature: Tests and Decisions lines may end with one sentence period
  A Tests line or a Decisions item that is valid apart from one period directly after its closing
  parenthesis passes the Intent check, and so does the same line without the period. Every other
  malformed line fails exactly as before, with the same problem text.

  Scenario: Tests lines pass with or without one trailing period, malformed ones fail as before
    When the k-line-period Intent check reads each line alone in an otherwise valid Intent:
      | section | line                                                                                     | problem                                                                                                                                                       |
      | Tests   | - is_even returns True for even integers: add test_is_even in tests/test_calc.py (unit)  |                                                                                                                                                               |
      | Tests   | - is_even returns True for even integers: add test_is_even in tests/test_calc.py (unit). |                                                                                                                                                               |
      | Tests   | - shaping refuses a bad line: add TestBadLine in cli/project/intent_test.go (integration). |                                                                                                                                                             |
      | Tests   | - the approval card shows the line: scenario 2 (scenario).                               |                                                                                                                                                               |
      | Tests   | - the reported failure: add TestReported (regression).                                   |                                                                                                                                                               |
      | Tests   | - the earlier behavior: the existing tests (existing).                                   |                                                                                                                                                               |
      | Tests   | - none: documentation only.                                                              |                                                                                                                                                               |
      | Tests   | - no layer here.                                                                         | tests: - no layer here. must be `- <rule>: <test to add or update> (<layer>)` or `- none: <reason>`                                                           |
      | Tests   | - is_even rejects floats: add test_float.                                                | tests: - is_even rejects floats: add test_float. must be `- <rule>: <test to add or update> (<layer>)` or `- none: <reason>`                                  |
      | Tests   | - is_even rejects floats: add test_float (bogus).                                        | tests: - is_even rejects floats: add test_float (bogus). must be `- <rule>: <test to add or update> (<layer>)` or `- none: <reason>`                          |
      | Tests   | - add test_float in tests/test_calc.py (unit).                                           | tests: - add test_float in tests/test_calc.py (unit). must be `- <rule>: <test to add or update> (<layer>)` or `- none: <reason>`                             |
      | Tests   | - is_even rejects floats: (unit).                                                        | tests: - is_even rejects floats: (unit). must be `- <rule>: <test to add or update> (<layer>)` or `- none: <reason>`                                          |
      | Tests   | - is_even rejects floats: add test_float (unit)..                                        | tests: - is_even rejects floats: add test_float (unit).. must be `- <rule>: <test to add or update> (<layer>)` or `- none: <reason>`                           |
      | Tests   | - is_even rejects floats: add test_float (unit). Extra words                             | tests: - is_even rejects floats: add test_float (unit). Extra words must be `- <rule>: <test to add or update> (<layer>)` or `- none: <reason>`               |
      | Tests   | - is_even rejects floats: add test_float (unit) .                                        | tests: - is_even rejects floats: add test_float (unit) . must be `- <rule>: <test to add or update> (<layer>)` or `- none: <reason>`                          |
      | Tests   | - is_even rejects floats: add test_float (unit)!                                         | tests: - is_even rejects floats: add test_float (unit)! must be `- <rule>: <test to add or update> (<layer>)` or `- none: <reason>`                           |
      | Tests   | - is_even rejects floats: add test_float (unit) and more                                 | tests: - is_even rejects floats: add test_float (unit) and more must be `- <rule>: <test to add or update> (<layer>)` or `- none: <reason>`                   |
    Then the k-line-period Intent check reports exactly the expected problem of each line

  Scenario: Decisions items pass with or without one trailing period, malformed ones fail as before
    When the k-line-period Intent check reads each line alone in an otherwise valid Intent:
      | section   | line                                                      | problem                              |
      | Decisions | - Non-integers raise TypeError. (source: request)         |                                      |
      | Decisions | - Non-integers raise TypeError. (source: request).        |                                      |
      | Decisions | - Non-integers raise TypeError. (source: answer 2)        |                                      |
      | Decisions | - Non-integers raise TypeError. (source: answer 12).      |                                      |
      | Decisions | - Non-integers raise TypeError.                           | decisions: a decision has no source  |
      | Decisions | - Non-integers raise TypeError (source: answer x).        | decisions: a decision has no source  |
      | Decisions | - Non-integers raise TypeError (source: caller).          | decisions: a decision has no source  |
      | Decisions | - Non-integers raise TypeError (source: request.)         | decisions: a decision has no source  |
      | Decisions | - Non-integers raise TypeError (source: request)..        | decisions: a decision has no source  |
      | Decisions | - Non-integers raise TypeError (source: request). Extra   | decisions: a decision has no source  |
      | Decisions | - Non-integers raise TypeError (source: request) .        | decisions: a decision has no source  |
      | Decisions | - Non-integers raise TypeError (source: request)!         | decisions: a decision has no source  |
    Then the k-line-period Intent check reports exactly the expected problem of each line

  Scenario: Shape publishes period-ended lines on the first submission and keeps them as written
    When the k-line-period scripted Shape submits the is-even Intent with these lines:
      | section   | line                                                                                        |
      | Decisions | - Non-integers raise TypeError. (source: request).                                          |
      | Tests     | - is_even returns True for even integers: add test_is_even in tests/test_calc.py (unit).    |
      | Tests     | - is_even returns False for odd integers: add test_is_odd in tests/test_calc.py (existing) |
    Then the k-line-period Shape exits 0 after 1 shaper request with no refused submission
    And the k-line-period published intent.md is the submitted bytes with every line as written
    And the k-line-period approval card exits 5

  Scenario: The specification states the accepted trailing period
    Then the k-line-period file "spec/prose/02-shaping.md" contains:
      """
      A `## Tests` line or a `## Decisions` item may end with one period directly after its closing parenthesis; Kogen accepts it with or without that period and keeps the line as written.
      """
