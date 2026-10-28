Feature: Decision-check last-attempt fallback also covers flagged statements outside the Decisions section
  The driver mounts as a test with go -overlay and runs the real Shape path against a scripted native provider with a decision check, then the real approval card.

  Scenario: Two tagged Decisions lines and two prose fragments flagged unsupported are all marked on the last attempt
    When the k26e Shape plays "mixed"
    Then the k26e observation satisfies the contract of its mode

  Scenario: A flagged statement that is not in intent.md refuses the submission and changes nothing
    When the k26e Shape plays "missing"
    Then the k26e observation satisfies the contract of its mode

  Scenario: A contradicting item still refuses the submission
    When the k26e Shape plays "contradicts"
    Then the k26e observation satisfies the contract of its mode
