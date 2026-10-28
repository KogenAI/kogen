Feature: Decision-check last-attempt fallback and a record of every refused submission
  The driver mounts as a test with go -overlay and runs the real Shape path against scripted fakes (a native provider with a decision check, or a scripted external shaper with the request audit), then the real approval card.

  Scenario: A decision flagged unsupported on every attempt is marked as an assumption on the last attempt
    When the k26c Shape plays "unsupported"
    Then the k26c observation satisfies the contract of its mode

  Scenario: A contradicting decision is never published
    When the k26c Shape plays "contradicts"
    Then the k26c observation satisfies the contract of its mode

  Scenario: Refusal records are bounded to 20 lines of 300 characters
    When the k26c Shape plays "bounded"
    Then the k26c observation satisfies the contract of its mode

  Scenario: An external shaper correction keeps the files of a submission refused by the audit gate
    When the k26c Shape plays "wrapcol"
    Then the k26c observation satisfies the contract of its mode
