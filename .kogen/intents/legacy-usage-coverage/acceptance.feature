Feature: Reconcile native summary uncertainty with retained usage

  Scenario: Disclose the f463-style discrepancy without changing 84 retained rows
    Given legacy coverage evidence:
      """json
      {"runs":{"f4637b88":{"summary":{"outcome":"context_exhausted","unknown_requests":1,"provider_failure":{"code":"context_length_exceeded","event_kind":"error","type":"invalid_request_error"},"usage":{"input":28312420,"cached":5974784,"output":38982,"reasoning":2038},"attempt_usage":{"input":28312420,"cached":5974784,"output":38982,"reasoning":2038}},"rows":[{"repeat":83,"legacy":true,"input":100,"cached":20,"output":10,"reasoning":0},{"legacy":true,"input":28304120,"cached":5973124,"output":38152,"reasoning":2038}]}},"decoys":true}
      """
    When I read installed legacy coverage with arguments:
      """json
      ["f4637b88","--limit","2"]
      """
    Then legacy coverage reporting leaves evidence unchanged
    And the legacy coverage JSON contains:
      | schema_version                               | 1             |
      | kind                                         | "usage"       |
      | data.totals.requests                         | 84            |
      | data.totals.completed                        | 84            |
      | data.totals.failed                           | 0             |
      | data.totals.unknown_usage                    | 0             |
      | data.totals.known_input                      | 28312420      |
      | data.totals.known_cached                     | 5974784       |
      | data.totals.known_output                     | 38982         |
      | data.totals.known_reasoning                  | 2038          |
      | data.totals.unknown_fields.write             | 84            |
      | data.totals.legacy_without_ids               | 84            |
      | data.coverage.retained_attempts              | 84            |
      | data.coverage.retained_unknown_attempts      | 0             |
      | data.coverage.completed_operations          | null          |
      | data.coverage.summary_unknown_requests      | 1             |
      | data.coverage.unrepresented_unknown_requests| 1             |
      | data.coverage.status                        | "uncertain"   |
      | data.coverage.summaries.0.run_id             | "f4637b88"    |
      | data.coverage.summaries.0.source             | ".kogen/local/runs/f4637b88/result.json" |
      | data.coverage.summaries.0.provider_failure_code | "context_length_exceeded" |
      | data.coverage.omitted_summaries              | 0             |
      | data.requests.length                        | 2             |
      | data.omitted_rows                           | 82            |
      | data.truncated                              | false         |
      | data.groups.0.known_input                    | 28312420      |
    And the legacy coverage limitations include:
      | summary_usage_unrepresented |
      | legacy_without_ids          |
    And the legacy coverage human output includes:
      | Retained attempts: 84; unknown usage attempts: 0; completed logical operations: unknown |
      | Summary unknown requests: 1; unrepresented unknown requests: 1; reconciliation: uncertain |
      | Known input 28312420; cached 5974784 |
      | context_length_exceeded |

  Scenario: An absent native result does not prove zero missing usage
    Given legacy coverage evidence:
      """json
      {"runs":{"11111111":{"rows":[{"legacy":true,"input":100,"cached":20,"output":10,"reasoning":2}]}}}
      """
    When I read installed legacy coverage with arguments:
      """json
      ["11111111"]
      """
    Then legacy coverage reporting leaves evidence unchanged
    And the legacy coverage JSON contains:
      | data.totals.requests                          | 1           |
      | data.totals.failed                            | 0           |
      | data.totals.known_input                       | 100         |
      | data.coverage.summary_unknown_requests        | null        |
      | data.coverage.unrepresented_unknown_requests  | null        |
      | data.coverage.completed_operations            | null        |
      | data.coverage.status                          | "uncertain" |
      | data.coverage.summaries                       | []          |
    And the legacy coverage limitations include:
      | summary_coverage_unavailable |
    And the legacy coverage human output includes:
      | Summary unknown requests: unknown; unrepresented unknown requests: unknown; reconciliation: uncertain |

  Scenario: A summary-only unknown counter is not a failed row
    Given legacy coverage evidence:
      """json
      {"runs":{"11111111":{"summary":{"outcome":"stopped","unknown_requests":1},"rows":[]}}}
      """
    When I read installed legacy coverage with arguments:
      """json
      ["11111111"]
      """
    Then legacy coverage reporting leaves evidence unchanged
    And the legacy coverage JSON contains:
      | data.requests                                  | []          |
      | data.groups                                    | []          |
      | data.totals.requests                           | 0           |
      | data.totals.failed                             | 0           |
      | data.totals.unknown_usage                      | 0           |
      | data.totals.known_input                        | 0           |
      | data.coverage.summary_unknown_requests         | 1           |
      | data.coverage.unrepresented_unknown_requests   | 1           |
      | data.coverage.status                           | "uncertain" |
    And the legacy coverage human output includes:
      | Retained attempts: 0; unknown usage attempts: 0; completed logical operations: 0 |
      | Summary unknown requests: 1; unrepresented unknown requests: 1; reconciliation: uncertain |

  Scenario: An already retained unresolved failed operation is not missing twice
    Given legacy coverage evidence:
      """json
      {"runs":{"11111111":{"summary":{"outcome":"provider_error","unknown_requests":1},"rows":[{"operation":"done","input":100,"cached":20,"output":10,"reasoning":2},{"operation":"failed","outcome":"failed"}]}}}
      """
    When I read installed legacy coverage with arguments:
      """json
      ["11111111"]
      """
    Then legacy coverage reporting leaves evidence unchanged
    And the legacy coverage JSON contains:
      | data.totals.requests                           | 2            |
      | data.totals.completed                          | 1            |
      | data.totals.failed                             | 1            |
      | data.totals.unknown_usage                      | 1            |
      | data.totals.known_input                        | 100          |
      | data.coverage.retained_unknown_attempts        | 1            |
      | data.coverage.completed_operations            | 1            |
      | data.coverage.summary_unknown_requests         | 1            |
      | data.coverage.unrepresented_unknown_requests   | 0            |
      | data.coverage.status                           | "reconciled" |
    And the legacy coverage human output includes:
      | Retained attempts: 2; unknown usage attempts: 1; completed logical operations: 1 |
      | Summary unknown requests: 1; unrepresented unknown requests: 0; reconciliation: reconciled |

  Scenario: Observed fallback uncertainty belongs to a physical attempt not a tenth logical operation
    Given legacy coverage evidence:
      """json
      {"runs":{"11111111":{"summary":{"outcome":"completed","unknown_requests":0},"rows":[{"operation":"retry","outcome":"failed","cache_status":"unsupported"},{"operation":"retry","input":100,"cached":20,"output":10,"reasoning":2},{"repeat":8,"input":100,"cached":20,"output":10,"reasoning":2}],"logical_completions":true}}}
      """
    When I read installed legacy coverage with arguments:
      """json
      ["11111111","--limit","1"]
      """
    Then legacy coverage reporting leaves evidence unchanged
    And the legacy coverage JSON contains:
      | data.totals.requests                           | 10           |
      | data.totals.completed                          | 9            |
      | data.totals.failed                             | 1            |
      | data.totals.unknown_usage                      | 1            |
      | data.totals.known_input                        | 900          |
      | data.totals.known_cached                       | 180          |
      | data.coverage.retained_attempts                | 10           |
      | data.coverage.completed_operations            | 9            |
      | data.coverage.summary_unknown_requests         | 0            |
      | data.coverage.unrepresented_unknown_requests   | 0            |
      | data.coverage.status                           | "reconciled" |
      | data.requests.length                           | 1            |
      | data.omitted_rows                              | 9            |
    And the legacy coverage human output includes:
      | Retained attempts: 10; unknown usage attempts: 1; completed logical operations: 9 |
      | Summary unknown requests: 0; unrepresented unknown requests: 0; reconciliation: reconciled |

  Scenario: A linear root and resumed child share a cumulative summary counter
    Given legacy coverage evidence:
      """json
      {"runs":{"11111111":{"summary":{"outcome":"context_exhausted","unknown_requests":1},"rows":[{"legacy":true,"input":100,"cached":20,"output":10,"reasoning":2}]},"22222222":{"summary":{"resumed_from":"11111111","root_build":"11111111","outcome":"stopped","unknown_requests":1},"rows":[{"operation":"child","input":200,"cached":40,"output":20,"reasoning":4}]},"33333333":{"summary":{"outcome":"stopped","unknown_requests":8},"rows":[{"input":999,"cached":99,"output":9,"reasoning":1}]}}}
      """
    When I read installed legacy coverage with arguments:
      """json
      ["22222222","--lineage","--limit","1"]
      """
    Then legacy coverage reporting leaves evidence unchanged
    And the legacy coverage JSON contains:
      | data.totals.requests                            | 2           |
      | data.totals.known_input                         | 300         |
      | data.totals.known_cached                        | 60          |
      | data.coverage.summary_unknown_requests          | 1           |
      | data.coverage.unrepresented_unknown_requests    | 1           |
      | data.coverage.status                            | "uncertain" |
      | data.coverage.summaries.length                   | 1           |
      | data.coverage.summaries.0.run_id                 | "11111111"  |
      | data.coverage.omitted_summaries                  | 1           |
      | data.requests.length                            | 1           |
      | data.omitted_rows                               | 1           |
    And the legacy coverage human output includes:
      | Summary unknown requests: 1; unrepresented unknown requests: 1; reconciliation: uncertain |

  Scenario: Selecting only a resumed child cannot allocate inherited uncertainty
    Given legacy coverage evidence:
      """json
      {"runs":{"11111111":{"summary":{"unknown_requests":1},"rows":[]},"22222222":{"summary":{"resumed_from":"11111111","root_build":"11111111","unknown_requests":1},"rows":[{"operation":"child","input":200,"cached":40,"output":20,"reasoning":4}]}}}
      """
    When I read installed legacy coverage with arguments:
      """json
      ["22222222"]
      """
    Then legacy coverage reporting leaves evidence unchanged
    And the legacy coverage JSON contains:
      | data.totals.requests                            | 1           |
      | data.totals.known_input                         | 200         |
      | data.coverage.completed_operations             | 1           |
      | data.coverage.summary_unknown_requests          | null        |
      | data.coverage.unrepresented_unknown_requests    | null        |
      | data.coverage.summaries.0.run_id                 | "22222222"  |
      | data.coverage.summaries.0.unknown_requests       | 1           |
      | data.coverage.status                            | "uncertain" |
    And the legacy coverage limitations include:
      | summary_scope_unattributed |
    And the legacy coverage human output includes:
      | Summary unknown requests: unknown; unrepresented unknown requests: unknown; reconciliation: uncertain |

  Scenario: An outcome slice keeps summary uncertainty visible without assigning it to completed rows
    Given legacy coverage evidence:
      """json
      {"runs":{"11111111":{"summary":{"outcome":"context_exhausted","unknown_requests":1},"rows":[{"operation":"done","phase":"build","input":100,"cached":20,"output":10,"reasoning":2},{"operation":"done-review","phase":"review","input":200,"cached":40,"output":20,"reasoning":4},{"operation":"failed","phase":"build","outcome":"failed"}]}}}
      """
    When I read installed legacy coverage with arguments:
      """json
      ["11111111","--outcome","completed","--group-by","role","--limit","1"]
      """
    Then legacy coverage reporting leaves evidence unchanged
    And the legacy coverage JSON contains:
      | data.scope.filters.outcome                      | "completed" |
      | data.totals.requests                            | 2           |
      | data.totals.failed                              | 0           |
      | data.totals.known_input                         | 300         |
      | data.groups.length                              | 2           |
      | data.groups.0.key.role                          | "build"     |
      | data.groups.0.known_input                       | 100         |
      | data.groups.1.key.role                          | "review"    |
      | data.groups.1.known_input                       | 200         |
      | data.coverage.completed_operations             | 2           |
      | data.coverage.summary_unknown_requests          | null        |
      | data.coverage.unrepresented_unknown_requests    | null        |
      | data.coverage.summaries.0.unknown_requests       | 1           |
      | data.coverage.status                            | "uncertain" |
      | data.requests.length                            | 1           |
      | data.omitted_rows                               | 1           |
    And the legacy coverage limitations include:
      | summary_scope_unattributed |
    And the legacy coverage human output includes:
      | Retained attempts: 2; unknown usage attempts: 0; completed logical operations: 2 |
      | Summary unknown requests: unknown; unrepresented unknown requests: unknown; reconciliation: uncertain |
