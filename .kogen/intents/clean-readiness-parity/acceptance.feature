Feature: Clean final candidate readiness
  Scenario: Shape exposes undeclared bootstrap while exploration stays warm
    When I qualify clean readiness parity in mode "shape-negative"
    Then the clean readiness parity observations are:
      | final dependency present | false |
      | final build present      | false |
      | final disposable         | true  |
      | accounted failed         | true  |
      | diagnostic inspected     | true  |
      | warm probe succeeded     | true  |
      | acceptance executions    | 1     |
      | clean record             | true  |
      | caller custody           | true  |
      | disposable cleaned       | true  |

  Scenario: Shape setup rebuilds ignored outputs in the exact candidate
    When I qualify clean readiness parity in mode "shape-setup"
    Then the clean readiness parity observations are:
      | final dependency present | true |
      | final build present      | true |
      | final disposable         | true |
      | setup started cold       | true |
      | all passed               | true |
      | exact inputs and env     | true |
      | warm probe succeeded     | true |
      | clean record             | true |
      | caller custody           | true |
      | disposable cleaned       | true |

  Scenario: Refine keeps warm preparation out of changed final proof
    When I qualify clean readiness parity in mode "refine"
    Then the clean readiness parity observations are:
      | final disposable              | true |
      | setup started cold            | true |
      | all passed                    | true |
      | accumulated package published | true |
      | original retained             | true |
      | candidate setup executions    | 1    |
      | raw approval archived         | true |
      | caller custody                | true |
      | clean record                  | true |
      | disposable cleaned            | true |

  Scenario: Refine accounts red once and acknowledges the exact candidate
    When I qualify clean readiness parity in mode "refine-red"
    Then the clean readiness parity observations are:
      | final dependency present      | false |
      | final build present           | false |
      | final disposable              | true  |
      | accounted failed              | true  |
      | diagnostic inspected          | true  |
      | candidate setup executions    | 1     |
      | acceptance executions         | 1     |
      | accumulated package published | true  |
      | raw approval archived         | true  |
      | caller custody                | true  |
      | clean record                  | true  |

  Scenario Outline: Approval misses cannot inherit workspace warmth
    When I qualify clean readiness parity in mode "<mode>"
    Then the clean readiness parity observations are:
      | final dependency present | false |
      | final build present      | false |
      | final disposable         | true  |
      | accounted failed         | true  |
      | acceptance executions    | 1     |
      | caller custody           | true  |
      | clean record             | true  |
    Examples:
      | mode             |
      | card-negative    |
      | approve-negative |

  Scenario: Clean proof reuse has exact candidate identity and honest legacy misses
    When I qualify clean readiness parity in mode "cache"
    Then the clean readiness parity observations are:
      | clean record                      | true |
      | exact repeat executions           | 0    |
      | ignored change executions         | 0    |
      | legacy executions                 | 1    |
      | nonignored addition executions    | 1    |
      | nonignored content executions     | 1    |
      | nonignored deletion executions    | 1    |
      | mode change executions            | 1    |
      | head change executions            | 1    |
      | protected change executions       | 1    |
      | declaration change executions     | 1    |
      | legacy original miss              | true |
      | legacy original setup executions  | 1    |
      | fresh candidate setup executions  | 1    |
      | caller index unchanged            | true |

  Scenario Outline: Unstable inputs cannot publish clean evidence
    When I qualify clean readiness parity in mode "<mode>"
    Then the clean readiness parity observations are:
      | refused               | true |
      | no clean evidence     | true |
      | no approval           | true |
      | caller index unchanged| true |
      | root effect honest    | true |
      | disposable cleaned    | true |
    Examples:
      | mode             |
      | scratch-mutation |
      | root-drift       |
