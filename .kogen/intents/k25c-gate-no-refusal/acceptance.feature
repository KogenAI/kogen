Feature: The audit coverage gate gives a template and never refuses on the last attempt
  The driver mounts as a test with go -overlay and runs the real native Shape path against a scripted provider, then the real approval card. The request holds the example "Example: is_even(0) returns True." and the rule "Rule B: zero returns False."; the scripted audit reports that conflict with exposing input is_even(0).

  Scenario: A shaper that never covers the defect is fed back twice and published on the last attempt
    When the k25c Shape plays "never"
    Then the k25c observation satisfies the contract of its mode

  Scenario: A shaper that pastes the template covers the defect on the next attempt
    When the k25c Shape plays "paste"
    Then the k25c observation satisfies the contract of its mode

  Scenario: An undefined defect gets a definition template and a question alternative
    When the k25c Shape plays "undefined_template"
    Then the k25c observation satisfies the contract of its mode
