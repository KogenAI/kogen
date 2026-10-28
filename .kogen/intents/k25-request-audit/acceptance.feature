Feature: Shape audits the request for conflicts and gates publication on coverage
  The driver mounts as a test with go -overlay and runs the real native Shape path against a scripted provider. The request holds the example "Example: is_even(0) returns True." and the rule "Rule B: zero returns False."; the scripted audit reports that conflict with exposing input is_even(0).

  Scenario: A clean audit publishes in one shaper round and is recorded
    When the k25 Shape plays "clean"
    Then the k25 observation satisfies the contract of its mode

  Scenario: An uncovered defect is fed back and the corrected Decision publishes
    When the k25 Shape plays "decision"
    Then the k25 observation satisfies the contract of its mode

  Scenario: A Decision stating both results does not cover the defect
    When the k25 Shape plays "ambiguous"
    Then the k25 observation satisfies the contract of its mode

  Scenario: A question containing both quotes covers the defect
    When the k25 Shape plays "question"
    Then the k25 observation satisfies the contract of its mode

  Scenario: A question containing only one quote does not cover the defect
    When the k25 Shape plays "partial"
    Then the k25 observation satisfies the contract of its mode

  Scenario: Without shape_audit Shape makes no audit request and records no audit event
    When the k25 Shape plays "off"
    Then the k25 observation satisfies the contract of its mode

  Scenario: An unknown key under shape_audit is refused before any provider request
    When the k25 Shape plays "badkey"
    Then the k25 observation satisfies the contract of its mode
