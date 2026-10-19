Feature: Compact native shaping context
  Index-first navigation removes automatic source-body fan-out without losing
  mandatory contracts, exact source access, or native authority boundaries.

  Scenario: Common words and licences do not fan out bodies
    When I inspect the compact context corpus through the native renderer
    Then the compact context observations are:
      | optional_excerpts         | 0    |
      | optional_body_bytes       | 0    |
      | all_paths_hashes_sizes    | true |
      | signature_integrity       | true |
      | exact_original_range      | true |
      | discovery_works           | true |
      | deterministic             | true |
      | input_measurement_exact   | true |

  Scenario: Explicit excerpts reference the index without repeating entries
    When I render explicit compact context excerpts
    Then the compact context observations are:
      | header_keys               | ["end_line","path","sha256","start_line"] |
      | excerpt_path              | features/steps/window.js                  |
      | start_line                | 97                                        |
      | end_line                  | 176                                       |
      | body_lines                | 80                                        |
      | body_bound                | true                                      |
      | body_matches_source       | true                                      |
      | exact_hash                | true                                      |
      | shared_root_revision      | true                                      |
      | no_repeated_entry_fields  | true                                      |

  Scenario: Default sequential Shape retains full settled context
    When I exercise compact context through native "shape"
    Then the compact context observations are:
      | exit_code                 | 0    |
      | optional_excerpts         | 0    |
      | optional_body_bytes       | 0    |
      | shared_root_revision      | true |
      | mandatory_exact           | true |
      | exact_tool_range          | true |
      | default_sequential        | true |
      | native_readiness          | true |
      | no_approval               | true |
      | head_index_unchanged      | true |
      | serialized_bytes_captured | true |

  Scenario: Refine preserves exact originals and proposals
    When I exercise compact context through native "refine"
    Then the compact context observations are:
      | exit_code                 | 0    |
      | optional_excerpts         | 0    |
      | optional_body_bytes       | 0    |
      | shared_root_revision      | true |
      | mandatory_exact           | true |
      | exact_tool_range          | true |
      | original_proposed_exact   | true |
      | native_readiness          | true |
      | no_approval               | true |
      | head_index_unchanged      | true |
      | serialized_bytes_captured | true |
