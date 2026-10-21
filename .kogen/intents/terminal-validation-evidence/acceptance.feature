Feature: Safe local evidence for rejected terminal responses
  Scenario: Distinguish evaluated predicates without accepting invalid output
    When I exercise terminal validation evidence through the real local transport
    Then the terminal rejection categories are:
      | fixture          | reasons                                      |
      | status           | response_status                              |
      | error            | response_error                               |
      | usage            | usage_shape                                  |
      | output-shape     | terminal_output_shape                        |
      | event-shape      | item_event_shape                             |
      | coverage         | terminal_index_coverage                      |
      | gap              | noncontiguous_indexes                        |
      | pending          | pending_items                                |
      | arguments        | item_shape                                   |
      | item-status      | item_status                                  |
      | unknown-item     | item_shape,item_status                       |
      | envelope         | empty_output,terminal_envelope                |
      | empty            | empty_output                                 |
      | replaced-invalid | item_shape                                   |
      | saturated        | item_shape                                   |
    And the terminal evidence observations are:
      | safe bounded structural metadata | true |
      | direct failures retain unknown usage | true |
      | invalid items not returned | true |
      | saturated counts | true |
      | effective replacement facts | true |
      | unknown type and status categorized | true |
      | no adversarial strings in output or events | true |

  Scenario: Preserve documented completion and retry semantics
    When I exercise terminal validation evidence through the real local transport
    Then the terminal evidence observations are:
      | documented stream exact output | true |
      | documented terminal exact output | true |
      | terminal replacement exact output | true |
      | valid usage preserved | true |
      | invalid retry exact output | true |
      | retry attempt statuses | ["failed","completed"] |
      | retry attempts | 2 |
      | retry failure usage unknown | true |
      | retry failed predicate | usage_shape |
      | no adversarial strings in output or events | true |

  Scenario: Diagnose the next native Shape without gaining authority
    When I exercise terminal validation evidence through installed native Shape
    Then the terminal evidence observations are:
      | native exit | 4 |
      | native prefix preserved | true |
      | native attempt statuses | ["failed","failed"] |
      | native failure usage unknown | true |
      | native predicates | [["response_status"],["item_shape"]] |
      | native requests after init | 2 |
      | native tool outputs | 0 |
      | native no Intent or helper | true |
      | native authority unchanged | true |
      | native evidence and output private | true |
