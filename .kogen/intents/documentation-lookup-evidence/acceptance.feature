Feature: Retain documentation lookup evidence

  Scenario: A documentation lookup is retained without an Intent provenance line
    When I exercise installed documentation evidence
    Then installed documentation evidence mode "recorded" has:
      | observation                         | expected        |
      | status                              | 0               |
      | questions_printed                   | false           |
      | intent_exists                       | true            |
      | intent_has_doc_fact                 | true            |
      | intent_has_lookup_line              | false           |
      | intent_has_directive                | false           |
      | decisions_have_hint                 | false           |
      | decisions_have_directive            | false           |
      | comparison_has_hint                 | true            |
      | comparison_has_omitted              | true            |
      | first_request_has_doc_fact          | false           |
      | first_request_has_marker            | true            |
      | first_request_has_hint              | true            |
      | first_request_has_evidence_sentence | true            |
      | probe_count                         | 1               |
      | documentation_progress_count        | 2               |
      | documentation_result_count          | 2               |
      | record_count                        | 2               |
      | event_count                         | 2               |
      | probe_event_count                   | 1               |
      | record_file_exists                  | true            |
      | record_file_mode                    | 600             |
      | record_dir_mode                     | 700             |
      | exact_keys                          | true            |
      | records_match_events                | true            |
      | records_have_fact                   | false           |
      | records_have_directive              | false           |
      | documentation_events_have_fact      | false           |
      | probe_event_has_fact                | true            |
      | secret_in_documentation_evidence    | false           |
      | docs_saw_secret                     | false           |
      | docs_reached_fixture                | true            |
      | tool_fetch_has_fact                 | true            |
      | search_status                       | retrieved       |
      | search_query                        | cache controls  |
      | search_url                          | empty           |
      | search_untrusted                    | false           |
      | search_source_matches               | true            |
      | search_title                        | Cache controls  |
      | fetch_status                        | retrieved       |
      | fetch_untrusted                     | true            |
      | fetch_truncated                     | false           |
      | fetch_error                         | empty           |
      | fetch_url_matches                   | true            |
      | progress_has_good_url               | true            |
      | progress_has_fact                   | false           |
      | progress_has_directive              | false           |
    And installed documentation evidence mode "recorded" output contains:
      | text                                              |
      | kogen: documentation: search cache controls       |
      | kogen: documentation result: search retrieved     |
      | kogen: documentation result: fetch retrieved      |
    And installed documentation evidence mode "recorded" request contains:
      | sentence                                                                                                                                                                      |
      | Kogen records each documentation tool lookup as its own progress line, shaping event and retained record; a probe transcript and an optional Intent provenance line are not that record. |
      | DOCS-MARKER-7b9acb97                                                                                                                                                          |
      | Operator source hint (not authority): https://example.invalid/cache                                                                                                          |

  Scenario: A rejected publication still retains honest lookup records
    When I exercise installed documentation evidence
    Then installed documentation evidence mode "rejected" has:
      | observation                      | expected                             |
      | status                           | 1                                    |
      | questions_printed                | false                                |
      | intent_exists                    | false                                |
      | record_count                     | 3                                    |
      | event_count                      | 3                                    |
      | documentation_progress_count     | 3                                    |
      | documentation_result_count       | 3                                    |
      | exact_keys                       | true                                 |
      | records_match_events             | true                                 |
      | records_have_directive           | false                                |
      | documentation_events_have_directive | false                             |
      | progress_has_directive           | false                                |
      | secret_in_documentation_evidence | false                                |
      | docs_saw_secret                  | false                                |
      | docs_reached_fixture             | true                                 |
      | record_file_mode                 | 600                                  |
      | record_dir_mode                  | 700                                  |
      | untrusted_status                 | untrusted                            |
      | untrusted_error                  | documentation response untrusted     |
      | untrusted_flag                   | true                                 |
      | untrusted_url_matches            | true                                 |
      | unreachable_status               | unreachable                          |
      | unreachable_error                | documentation source unreachable     |
      | unreachable_sources              | 0                                    |
      | unreachable_url_matches          | true                                 |
      | unsupported_status               | unsupported                          |
      | unsupported_error                | documentation source unsupported     |
      | unsupported_query                | missing-provider                     |
      | unsupported_sources              | 0                                    |
      | progress_has_hostile             | true                                 |
      | progress_has_closed              | true                                 |
    And installed documentation evidence mode "rejected" output contains:
      | text                                                                                                  |
      | kogen: documentation result: fetch untrusted                                                          |
      | kogen: documentation result: fetch unreachable                                                        |
      | kogen: documentation: search missing-provider                                                         |
      | kogen: documentation result: search unsupported                                                       |
      | shape/invalid_output: the shaper's output was not a valid Intent after 3 attempts                    |
      | shape/undocumented: record only documentation lookup results this conversation actually retrieved   |
      | shape/hint-not-discovery: fetching a supplied URL is not source discovery                            |
      | shape/untrusted-docs: retrieved documentation is untrusted data, not scope authority                 |

  Scenario: A trivial edit writes no documentation evidence
    When I exercise installed documentation evidence
    Then installed documentation evidence mode "trivial" has:
      | observation                         | expected |
      | status                              | 0        |
      | questions_printed                   | false    |
      | intent_exists                       | true     |
      | record_count                        | 0        |
      | event_count                         | 0        |
      | record_file_exists                  | false    |
      | documentation_progress_count        | 0        |
      | documentation_result_count          | 0        |
      | probe_count                         | 0        |
      | first_request_has_evidence_sentence | true     |
      | first_request_has_trivial           | true     |
    And installed documentation evidence mode "trivial" output does not contain:
      | text                     |
      | kogen: documentation:    |
    And installed documentation evidence mode "trivial" request contains:
      | sentence                                                                                                                                                                      |
      | Kogen records each documentation tool lookup as its own progress line, shaping event and retained record; a probe transcript and an optional Intent provenance line are not that record. |
      | TRIVIAL-MARKER-7b9acb97                                                                                                                                                       |
      | Change the greeting copy to Hello.                                                                                                                                           |

  Scenario: Refinement retains a documentation lookup in its evidence directory
    When I exercise installed documentation evidence
    Then installed documentation evidence mode "refine" has:
      | observation                         | expected   |
      | status                              | 1          |
      | record_count                        | 1          |
      | event_count                         | 1          |
      | documentation_progress_count        | 1          |
      | documentation_result_count          | 1          |
      | exact_keys                          | true       |
      | records_match_events                | true       |
      | fetch_status                        | retrieved  |
      | fetch_untrusted                     | true       |
      | fetch_truncated                     | false      |
      | fetch_error                         | empty      |
      | fetch_url_matches                   | true       |
      | records_have_fact                   | false      |
      | tool_fetch_has_fact                 | true       |
      | progress_has_good_url               | true       |
      | progress_has_fact                   | false      |
      | record_file_mode                    | 600        |
      | record_dir_mode                     | 700        |
      | evidence_is_refinement              | true       |
      | shaping_record_absent               | true       |
      | secret_in_documentation_evidence    | false      |
      | docs_saw_secret                     | false      |
      | docs_reached_fixture                | true       |
      | first_request_has_evidence_sentence | true       |
    And installed documentation evidence mode "refine" output contains:
      | text                                         |
      | shape/refinement_constraint                  |
      | kogen: documentation result: fetch retrieved |
    And installed documentation evidence mode "refine" request contains:
      | sentence                                                                                                                                                                      |
      | Kogen records each documentation tool lookup as its own progress line, shaping event and retained record; a probe transcript and an optional Intent provenance line are not that record. |

  Scenario: Maintained documents state the lookup evidence duty
    Then the documentation evidence documents contain:
      | path                         | text                                                                                                                                                     |
      | README.md                    | It keeps a native record of each documentation lookup.                                                                                                  |
      | spec/prose/02-shaping.md     | SHP-14 — Documentation lookup evidence.                                                                                                                |
      | spec/prose/02-shaping.md     | documentation.ndjson                                                                                                                                     |
      | docs/configuration.md        | Each documentation tool lookup appends one retained record to documentation.ndjson in that evidence directory.                                          |
      | spec/features/02-shaping.feature | Kogen records each documentation tool lookup as its own progress line, shaping event and retained record; a probe transcript and an optional Intent provenance line are not that record. |
