Feature: Preserve done items across empty terminal metadata
  # Local documented-shaped counterexamples, not captured provider payloads.
  Background:
    Given these documented compatibility items:
      """
      [{"type":"reasoning","id":"r0","summary":[]},{"type":"message","id":"m1","role":"assistant","status":"completed","content":[{"type":"output_text","text":"ready","annotations":[]}]},{"type":"function_call","id":"f2","call_id":"c2","name":"read_file","status":"completed","arguments":"{\"path\":\"app.txt\"}"},{"type":"function_call","id":"f3","call_id":"c3","name":"list_files","status":"completed","arguments":"{}"}]
      """

  Scenario: Empty metadata retains ordered done items and usage before socket closure
    When I run the compatibility HTTP stream "complete"
    Then the compatibility response contains exactly the documented items
    And the compatibility observations are:
      | outcome              | "ok"                                         |
      | usage                | {"input":100,"cached":5,"output":20,"reasoning":10} |
      | known_usage          | {"input":100,"cached":5,"output":20,"reasoning":10} |
      | requests             | 1                                            |
      | socket_open_seen     | true                                         |
      | socket_closed        | true                                         |
      | returned_before_hold | true                                         |

  Scenario Outline: Empty metadata retains refusal predicates instead of replacing observations
    When I run the compatibility HTTP stream "<mode>"
    Then the compatibility observations are:
      | outcome                    | "provider/invalid_response" |
      | returned_items             | false                       |
      | requests                   | 1                           |
      | failed_usage_unknown       | true                        |
      | safe_bounded_evidence      | true                        |
      | terminal_response_present  | true                        |
      | terminal_output_present    | true                        |
      | terminal_output_replaced   | false                       |
      | item_count                 | <items>                     |
      | pending_count              | <pending>                   |
      | observed_index_count       | <observed>                  |
      | reasons                    | <reasons>                   |

    Examples:
      | mode          | items | pending | observed | reasons                                |
      | pending       | 4     | 1       | 5        | ["pending_items"]                      |
      | malformed     | 4     | 0       | 4        | ["item_shape"]                         |
      | empty         | 0     | 0       | 0        | ["empty_output"]                       |
      | sticky        | 4     | 0       | 4        | ["item_event_shape"]                   |
      | usage         | 4     | 0       | 4        | ["usage_shape"]                        |
      | status        | 4     | 0       | 4        | ["response_status"]                    |
      | response-error| 4     | 0       | 4        | ["response_error"]                     |
      | gap           | 3     | 0       | 3        | ["noncontiguous_indexes"]              |

  Scenario Outline: Empty terminal metadata cannot hide a failed stream
    When I run the compatibility HTTP stream "<mode>"
    Then the compatibility observations are:
      | outcome              | "provider/refused" |
      | returned_items       | false              |
      | requests             | 1                  |
      | failed_usage_unknown | true               |
      | failure_event        | "<event>"          |

    Examples:
      | mode       | event               |
      | failed     | response.failed     |
      | incomplete | response.incomplete |
      | error      | error               |

  Scenario: Documented tools retained from empty metadata reach installed native Shape
    When I run installed compatibility Shape in mode "complete"
    Then the compatibility observations are:
      | exit                 | 5                     |
      | question_displayed   | true                  |
      | read_effect          | ["1\tbaseline"]       |
      | requests_after_init  | 2                     |
      | authority_unchanged  | true                  |
      | no_intent_or_helper  | true                  |

  Scenario Outline: Rejected retained tools never reach the installed Shape boundary
    When I run installed compatibility Shape in mode "<mode>"
    Then the compatibility observations are:
      | exit                 | 4                     |
      | question_displayed   | false                 |
      | read_effect          | []                    |
      | requests_after_init  | 2                     |
      | authority_unchanged  | true                  |
      | no_intent_or_helper  | true                  |

    Examples:
      | mode      |
      | pending   |
      | malformed |
