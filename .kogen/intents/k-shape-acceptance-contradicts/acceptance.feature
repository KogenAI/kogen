Feature: Shape checks each acceptance example against the Intent's rules
  The installed release shapes a prepared package through the scripted local provider. The shaper submits the package;
  Kogen makes one example check request per complete candidate whose only tool is submit_example_check, and the
  scripted check answers with the example's quotes and the value the package's rule gives for its input. Kogen alone
  compares each expected value with that derived value. The prepared packages' step definitions are trivial fixtures.

  Scenario: An arithmetic contradiction goes back to the shaper and its consistent version is accepted unchanged
    Given the prepared package "durations" states the rule "H is seconds div 3600, M is (seconds mod 3600) div 60 and S is seconds mod 60"
    And the prepared example "5430 seconds render as hours, minutes and seconds" has input "5430"
    And the example check of the prepared package derives "1 hour, 30 minutes, 30 seconds" because "5430 = 1*3600 + 30*60 + 30"
    When the shaper submits the prepared example expecting "1 hour, 1 minute, 30 seconds", then expecting "1 hour, 30 minutes, 30 seconds"
    Then shaping the prepared package exited with status 0
    And after its first prepared submission the shaper was told exactly:
      """
      Example check: 1 acceptance example(s) contradict the Intent's rules; nothing was published. Correct the expected value, the input or the rule so that each expected value follows from its input under the Intent's rules; do not remove or weaken an example to pass this check.
      - scenario: 5430 seconds render as hours, minutes and seconds | input: 5430 | expected: 1 hour, 1 minute, 30 seconds | rule: H is seconds div 3600, M is (seconds mod 3600) div 60 and S is seconds mod 60 | derived: 1 hour, 30 minutes, 30 seconds | why: 5430 = 1*3600 + 30*60 + 30
      """
    And every example check request offered only the tool "submit_example_check" and carried the request and the candidate package
    And the prepared package's shaping events record example check results "contradicts, follows"
    And shaping the prepared package printed the line "Next: kogen intent approve durations"
    And the published prepared package is exactly the one expecting "1 hour, 30 minutes, 30 seconds"
    And the approval card of the prepared package exits 5 and lists "5430 seconds render as hours, minutes and seconds (passes now)"

  Scenario: An expected value its fixed-width input cannot produce goes back to the shaper and its consistent version is accepted unchanged
    Given the prepared package "amounts" states the rule "the amount is columns 10-13 of the record: a sign and three digits counting hundredths, written with two decimals"
    And the prepared example "The amount of a record is read from columns 10-13" has input "ACCT00042-120EUR"
    And the example check of the prepared package derives "-1.20" because "columns 10-13 of ACCT00042-120EUR hold -120, that is -120 hundredths"
    When the shaper submits the prepared example expecting "-12.00", then expecting "-1.20"
    Then shaping the prepared package exited with status 0
    And after its first prepared submission the shaper was told exactly:
      """
      Example check: 1 acceptance example(s) contradict the Intent's rules; nothing was published. Correct the expected value, the input or the rule so that each expected value follows from its input under the Intent's rules; do not remove or weaken an example to pass this check.
      - scenario: The amount of a record is read from columns 10-13 | input: ACCT00042-120EUR | expected: -12.00 | rule: the amount is columns 10-13 of the record: a sign and three digits counting hundredths, written with two decimals | derived: -1.20 | why: columns 10-13 of ACCT00042-120EUR hold -120, that is -120 hundredths
      """
    And every example check request offered only the tool "submit_example_check" and carried the request and the candidate package
    And the prepared package's shaping events record example check results "contradicts, follows"
    And shaping the prepared package printed the line "Next: kogen intent approve amounts"
    And the published prepared package is exactly the one expecting "-1.20"
    And the approval card of the prepared package exits 5 and lists "The amount of a record is read from columns 10-13 (passes now)"

  Scenario: An order opposite to the Intent's stated order goes back to the shaper and its consistent version is accepted unchanged
    Given the prepared package "key-order" states the rule "keys are listed sorted bytewise ascending, joined by a comma and a space"
    And the prepared example "Keys are listed in bytewise ascending order" has input '{"b":1,"a":2,"C":3}'
    And the example check of the prepared package derives "C, a, b" because "bytewise C (0x43) sorts before a (0x61), and a before b (0x62)"
    When the shaper submits the prepared example expecting "b, a, C", then expecting "C, a, b"
    Then shaping the prepared package exited with status 0
    And after its first prepared submission the shaper was told exactly:
      """
      Example check: 1 acceptance example(s) contradict the Intent's rules; nothing was published. Correct the expected value, the input or the rule so that each expected value follows from its input under the Intent's rules; do not remove or weaken an example to pass this check.
      - scenario: Keys are listed in bytewise ascending order | input: {"b":1,"a":2,"C":3} | expected: b, a, C | rule: keys are listed sorted bytewise ascending, joined by a comma and a space | derived: C, a, b | why: bytewise C (0x43) sorts before a (0x61), and a before b (0x62)
      """
    And every example check request offered only the tool "submit_example_check" and carried the request and the candidate package
    And the prepared package's shaping events record example check results "contradicts, follows"
    And shaping the prepared package printed the line "Next: kogen intent approve key-order"
    And the published prepared package is exactly the one expecting "C, a, b"
    And the approval card of the prepared package exits 5 and lists "Keys are listed in bytewise ascending order (passes now)"

  Scenario Outline: A consistent <kind> example is accepted unchanged after one example check
    Given the prepared package "<slug>" states the rule "<rule>"
    And the prepared example "<scenario>" has input '<input>'
    And the example check of the prepared package derives "<expected>" because "<why>"
    When the shaper submits the prepared example expecting "<expected>"
    Then shaping the prepared package exited with status 0
    And every example check request offered only the tool "submit_example_check" and carried the request and the candidate package
    And the prepared package's shaping events record example check results "follows"
    And shaping the prepared package printed the line "Next: kogen intent approve <slug>"
    And the published prepared package is exactly the one expecting "<expected>"
    And the approval card of the prepared package exits 5 and lists "<scenario> (passes now)"

    Examples:
      | kind        | slug      | rule                                                                                                          | scenario                                           | input               | expected                       | why                                                                  |
      | arithmetic  | durations | H is seconds div 3600, M is (seconds mod 3600) div 60 and S is seconds mod 60                                 | 5430 seconds render as hours, minutes and seconds  | 5430                | 1 hour, 30 minutes, 30 seconds | 5430 = 1*3600 + 30*60 + 30                                           |
      | fixed-width | amounts   | the amount is columns 10-13 of the record: a sign and three digits counting hundredths, written with two decimals | The amount of a record is read from columns 10-13 | ACCT00042-120EUR    | -1.20                          | columns 10-13 of ACCT00042-120EUR hold -120, that is -120 hundredths |
      | ordering    | key-order | keys are listed sorted bytewise ascending, joined by a comma and a space                                      | Keys are listed in bytewise ascending order        | {"b":1,"a":2,"C":3} | C, a, b                        | bytewise C (0x43) sorts before a (0x61), and a before b (0x62)       |

  Scenario: A contradiction the shaper keeps is not marked ready and approval refuses the package
    Given the prepared package "durations" states the rule "H is seconds div 3600, M is (seconds mod 3600) div 60 and S is seconds mod 60"
    And the prepared example "5430 seconds render as hours, minutes and seconds" has input "5430"
    And the example check of the prepared package derives "1 hour, 30 minutes, 30 seconds" because "5430 = 1*3600 + 30*60 + 30"
    When the shaper submits the prepared example expecting "1 hour, 1 minute, 30 seconds" three times
    Then shaping the prepared package exited with status 1
    And shaping the prepared package printed these lines in order:
      """
      intent/not_ready: the Intent is not ready to build
        - scenario: 5430 seconds render as hours, minutes and seconds | input: 5430 | expected: 1 hour, 1 minute, 30 seconds | rule: H is seconds div 3600, M is (seconds mod 3600) div 60 and S is seconds mod 60 | derived: 1 hour, 30 minutes, 30 seconds | why: 5430 = 1*3600 + 30*60 + 30
      """
    And every example check request offered only the tool "submit_example_check" and carried the request and the candidate package
    And the prepared package's shaping events record example check results "contradicts, contradicts, contradicts"
    And the prepared package has no readiness evidence and no source receipt
    And the approval card of the prepared package exits 1 and printed these lines in order:
      """
      intent/examples_contradict: Shape's example check found acceptance examples that contradict the Intent's rules; correct the examples or the rules in the Intent's files, or delete .kogen/intents/durations/ and shape again
        - scenario: 5430 seconds render as hours, minutes and seconds | input: 5430 | expected: 1 hour, 1 minute, 30 seconds | rule: H is seconds div 3600, M is (seconds mod 3600) div 60 and S is seconds mod 60 | derived: 1 hour, 30 minutes, 30 seconds | why: 5430 = 1*3600 + 30*60 + 30
      """
    And approving the prepared package with its full hash exits 1, prints "intent/examples_contradict: Shape's example check found acceptance examples that contradict the Intent's rules; correct the examples or the rules in the Intent's files, or delete .kogen/intents/durations/ and shape again" and writes no approval marker

  Scenario: The shaping specification describes the example check and the approval refusal
    Then the shaping specification names the example check:
      | path                        | text                       |
      | spec/prose/02-shaping.md    | submit_example_check       |
      | spec/prose/02-shaping.md    | intent/examples_contradict |
