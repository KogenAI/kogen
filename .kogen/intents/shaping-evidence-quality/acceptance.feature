Feature: Qualify declared shaping evidence without waiving it
  Background:
    Given the shaping evidence controls:
      """json
      {
        "good":{"exit":0,"output":"accepted\n"},
        "bad":{"exit":1,"output":"rejected\n"},
        "capability":{"error":{"type":"invalid_request_error","code":"invalid_parameter","message":"prompt_cache_options is not supported on this model"}},
        "rejection_exit":23,
        "guidance":["outcome-critical","target route","known-good","known-bad","counterexamples","pixel","handoff"],
        "cases":[
          {"id":"json-object","good":{"actual_json":"{\"b\":2,\"a\":1}","expected_json":"{\"a\":1,\"b\":2}"},"bad":{"actual_json":"{\"b\":3,\"a\":1}","expected_json":"{\"a\":1,\"b\":2}"}},
          {"id":"json-array","good":{"actual":[1,2],"expected":[1,2]},"bad":{"actual":[2,1],"expected":[1,2]}},
          {"id":"json-string","good":{"actual":"a b","expected":"a b"},"bad":{"actual":"ab","expected":"a b"}},
          {"id":"oklch","good":{"actual":"oklch(0.5 0 0)","maximum":0.6},"bad":{"actual":"oklch(0.95 0 0)","maximum":0.6}},
          {"id":"markdown","good":{"actual":"<strong>Important</strong>","rendered":"<strong>Important</strong>","raw":"**Important**"},"bad":{"actual":"**Important**","rendered":"<strong>Important</strong>","raw":"**Important**"}},
          {"id":"search","good":{"events":[{"action":"search","results":["needle"]},{"action":"reset","results":[]}],"query":"needle"},"bad":{"events":[{"action":"search","results":[]},{"action":"reset","results":["needle"]}],"query":"needle"}},
          {"id":"history","good":{"seed":{"actor":"seed-user-7"},"actual":{"actor":"seed-user-7"}},"bad":{"seed":{"actor":"seed-user-7"},"actual":{"actor":"guessed-user"}}},
          {"id":"cold-output","good":{"stdout":"Compiling fixture\n<html>Ready</html>","payload":"<html>Ready</html>","expected":"<html>Ready</html>"},"bad":{"stdout":"<html>Ready</html>","payload":"Compiling fixture\n<html>Ready</html>","expected":"<html>Ready</html>"}},
          {"id":"legacy-84-plus-one","good":{"actual":{"data":{"totals":{"completed":84,"failed":0,"unknown_usage":0},"coverage":{"summary_unknown_requests":1,"unrepresented_unknown_requests":1}}},"expected":{"data":{"totals":{"completed":84,"failed":0,"unknown_usage":0},"coverage":{"summary_unknown_requests":1,"unrepresented_unknown_requests":1}}}},"bad":{"actual":{"data":{"totals":{"completed":84,"failed":0,"unknown_usage":0},"coverage":{"summary_unknown_requests":0,"unrepresented_unknown_requests":0}}},"expected":{"data":{"totals":{"completed":84,"failed":0,"unknown_usage":0},"coverage":{"summary_unknown_requests":1,"unrepresented_unknown_requests":1}}}}}
        ]
      }
      """

  Scenario: Keep no-obligation shaping ordinary and preserve source scope
    When I qualify native shaping evidence in mode "ordinary"
    Then the shaping evidence observations are:
      | shape exit                        | 0    |
      | acceptance executions             | 1    |
      | feasibility probe executions      | 0    |
      | card exit                         | 5    |
      | exact approval exit               | 0    |
      | Shape did not approve             | true |
      | complete request delivered        | true |
      | critical guidance delivered        | true |
      | unchanged caller index and HEAD   | true |

  Scenario: Reject an unproved capability and retain actual target rejection
    When I qualify native shaping evidence in mode "capability"
    Then the shaping evidence observations are:
      | shape exit                        | 0    |
      | unchanged acknowledgment refused  | true |
      | diagnostic names failed obligation| true |
      | actual rejection returned         | true |
      | exact proof                       | true |
      | product red retained              | true |
      | Shape did not approve             | true |
      | unchanged caller index and HEAD   | true |

  Scenario: Exercise a protected observer hidden behind missing-feature red
    When I qualify native shaping evidence in mode "masked"
    Then the shaping evidence observations are:
      | shape exit                        | 0    |
      | unchanged acknowledgment refused  | true |
      | diagnostic names failed obligation| true |
      | corrected observer published      | true |
      | exact proof                       | true |
      | product red retained              | true |
      | acceptance executions             | 1    |
      | Shape did not approve             | true |
      | unchanged caller index and HEAD   | true |

  Scenario: Carry the supplied bad observers into executed controls
    When I qualify native shaping evidence in mode "counterexamples"
    Then each evidence counterexample has these observations:
      | faulty observer refused | true |
      | corrected observer ready | true |
      | both controls executed | true |
      | exact proof | true |

  Scenario: Bind retained evidence to actual command input observer and outcome
    When I qualify native shaping evidence in mode "binding"
    Then the shaping evidence observations are:
      | initial proof                     | true |
      | controls on first card            | 2    |
      | controls on exact repeat          | 0    |
      | controls on exact approval        | 0    |
      | controls after observer change    | 2    |
      | controls after input change       | 2    |
      | controls after command change     | 2    |
      | controls after forged outcome     | 2    |
      | controls after missing proof      | 2    |
      | controls after HEAD change        | 2    |
      | final exact proof                 | true |

  Scenario: Enforce obligations during native refinement without new authority
    When I qualify native shaping evidence in mode "refine"
    Then the shaping evidence observations are:
      | bad refinement refused            | true |
      | unchanged acknowledgment refused  | true |
      | original package preserved        | true |
      | original approval preserved       | true |
      | good refinement exit              | 0    |
      | qualified refinement published    | true |
      | exact proof                       | true |
      | approval revoked not replaced     | true |
      | unchanged caller index and HEAD   | true |
