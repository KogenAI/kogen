Feature: Useful prompt reuse and honest local usage
  Scenario: Complete Shape authority and valid replay reach consecutive provider requests
    When I exercise prompt reuse through native "shape"
    Then the prompt reuse observations are:
      | exit_codes | [5,5] |
      | requests | 3 |
      | complete_original_and_answer | true |
      | supported_policy | true |
      | stable_prefix_and_tools | true |
      | exact_replay_order | true |
      | comparison_ids | [null,null,"resp_shape1"] |
      | forbidden_state_fields | false |
      | metadata_retained | true |
      | analytical_secrets_absent | true |

  Scenario: Build and saved review preserve reuse without sharing authority
    When I exercise prompt reuse through native "build-resume"
    Then the prompt reuse observations are:
      | exit_codes | [1,0] |
      | requests | 5 |
      | supported_policy | true |
      | stable_prefix_and_tools | true |
      | exact_replay_order | true |
      | comparison_ids | [null,"resp_build1",null,"resp_review1","resp_review2"] |
      | reviewer_independent | true |
      | review_fresh_candidate | true |
      | prior_result_unchanged | true |
      | blocker_preserved_until_resume | true |
      | landed_after_review | true |
      | forbidden_state_fields | false |
      | metadata_retained | true |
      | analytical_secrets_absent | true |

  Scenario Outline: Cache capability handling uses only safe necessary calls
    When I exercise prompt reuse through native "<mode>"
    Then the prompt reuse observations are:
      | requests | <calls> |
      | outcome | "<outcome>" |
      | first_has_cache_policy | <first> |
      | last_has_cache_policy | <last> |
      | forbidden_state_fields | false |
      | compatibility_visible | true |
    Examples:
      | mode | calls | outcome | first | last |
      | unsupported-option | 2 | completed | true | false |
      | legacy-model | 1 | completed | false | false |
      | unrelated-refusal | 1 | provider/model_unavailable | true | true |

  Scenario: Mixed retained attempts count once instead of adding summaries
    Given retained usage files for prompt reuse:
      """
      {
        "runs": {
          "11111111": {"slug":"cache-fixture","rows":[
            {"id":"resp_a","input":100,"cached":0,"write":40,"write_30m":40,"write_12h":0,"output":10,"reasoning":2},
            {"id":"resp_b","input":900,"cached":600,"write":100,"write_30m":60,"write_12h":40,"output":90,"reasoning":9},
            {"id":"resp_b","input":900,"cached":600,"write":100,"write_30m":60,"write_12h":40,"output":90,"reasoning":9},
            {"legacy":true,"input":200,"cached":100,"output":20,"reasoning":4},
            {"id":null,"outcome":"failed"}
          ]}
        },
        "shape":[{"input":50,"cached":25,"output":5,"reasoning":1}],
        "decoys":true
      }
      """
    When I run prompt reuse usage with arguments:
      """
      ["--json","--limit","2"]
      """
    Then the prompt reuse report has:
      | schema_version | 1 |
      | kind | "usage" |
      | error | null |
      | data.totals.requests | 5 |
      | data.totals.completed | 4 |
      | data.totals.failed | 1 |
      | data.totals.duplicate_responses | 1 |
      | data.totals.legacy_without_ids | 2 |
      | data.totals.unknown_usage | 1 |
      | data.totals.known_input | 1250 |
      | data.totals.known_cached | 725 |
      | data.totals.known_output | 125 |
      | data.totals.known_reasoning | 16 |
      | data.totals.known_write | 140 |
      | data.totals.known_write_30m | 100 |
      | data.totals.known_write_12h | 40 |
      | data.totals.cached_input_percent | 58 |
      | data.totals.zero_hit_requests | 1 |
      | data.requests.length | 2 |
      | data.omitted_rows | 3 |
      | data.truncated | false |
    And prompt reuse reporting is read only and excludes private content

  Scenario: Run lineage and retained dates select attempts not inherited usage
    Given retained usage files for prompt reuse:
      """
      {"runs":{
        "11111111":{"slug":"cache-fixture","rows":[{"legacy":true,"input":100,"cached":0,"output":10,"reasoning":2,"at":"2026-10-20T10:00:00Z"}]},
        "22222222":{"slug":"cache-fixture","parent":"11111111","rows":[{"id":"resp_child","input":900,"cached":600,"write":100,"write_30m":100,"write_12h":0,"output":90,"reasoning":9,"phase":"review","at":"2026-10-21T10:00:00Z"}]},
        "33333333":{"slug":"another-intent","rows":[{"legacy":true,"input":9999,"cached":9999,"output":1,"reasoning":0}]}
      }}
      """
    When I run prompt reuse usage with arguments:
      """
      ["11111111","--lineage","--json","--phase","review","--since","2026-10-21T00:00:00Z","--until","2026-10-22T00:00:00Z","--group-by","phase,effort"]
      """
    Then the prompt reuse report has:
      | data.totals.requests | 1 |
      | data.totals.known_input | 900 |
      | data.totals.known_cached | 600 |
      | data.groups.length | 1 |
      | data.groups.0.key.phase | "review" |
      | data.groups.0.key.effort | "high" |
      | data.requests.0.run_id | "22222222" |
    And prompt reuse reporting is read only and excludes private content

  Scenario: Invalid sums and missing writes stay uncertain
    Given retained usage files for prompt reuse:
      """
      {"runs":{"11111111":{"rows":[
        {"id":"resp_bad","input":10,"cached":11,"output":3,"reasoning":1},
        {"legacy":true,"input":0,"cached":0,"output":0,"reasoning":0}
      ]}}}
      """
    When I run prompt reuse usage with arguments:
      """
      ["--json"]
      """
    Then the prompt reuse report has:
      | data.totals.requests | 2 |
      | data.totals.inconsistent | 1 |
      | data.totals.known_input | 0 |
      | data.totals.known_cached | 0 |
      | data.totals.cached_input_percent | null |
      | data.totals.zero_hit_requests | 0 |
      | data.totals.unknown_fields.write | 2 |
    And prompt reuse reporting is read only and excludes private content

  Scenario: Empty history has honest JSON and human output
    Given retained usage files for prompt reuse:
      """
      {"runs":{}}
      """
    When I run prompt reuse usage with arguments:
      """
      ["--json"]
      """
    Then the prompt reuse report has:
      | data.totals.requests | 0 |
      | data.totals.cached_input_percent | null |
      | data.requests | [] |
      | data.groups | [] |
      | data.truncated | false |
    And prompt reuse reporting is read only and excludes private content
