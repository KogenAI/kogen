Feature: Bounded unsupported-cache capability repair
  Scenario Outline: Reproduce the observed nonexecuting refusal through real request construction
    When I send a cache capability conversation with:
      | mode    | success                                                      |
      | single  | <single>                                                     |
      | status  | 400                                                          |
      | type    | invalid_request_error                                        |
      | code    | invalid_parameter                                            |
      | message | prompt_cache_options is not supported on this model            |
      | param   | <param>                                                      |
    Then the cache capability observations are:
      | outcomes                 | ["completed","completed"] |
      | requests                 | 3                           |
      | controls                 | [true,false,false]          |
      | fallback_preserves_body  | true                        |
      | later_preserves_replay   | true                        |
      | exact_completed_items    | true                        |
      | honest_attempts          | true                        |
      | independent_fresh        | true                        |
    Examples:
      | single | param                |
      | false  | absent               |
      | true   | absent               |
      | false  | prompt_cache_options |
      | true   | prompt_cache_options |
      | false  | null                 |

  Scenario Outline: Keep older recognized cache refusals working
    When I send a cache capability conversation with:
      | mode    | success          |
      | single  | true             |
      | status  | 400              |
      | type    | invalid_request_error |
      | code    | <code>           |
      | message | unsupported      |
      | param   | <param>          |
    Then the cache capability observations are:
      | outcomes                | ["completed","completed"] |
      | requests                | 3                           |
      | controls                | [true,false,false]          |
      | fallback_preserves_body | true                        |
      | honest_attempts         | true                        |
    Examples:
      | code                                         | param                                         |
      | unsupported_parameter                        | prompt_cache_options                          |
      | unknown_parameter                            | input[0].content[0].prompt_cache_breakpoint    |
      | subscription_sharing_unsupported_capability   | prompt_cache_options                          |

  Scenario Outline: Do not reinterpret unrelated errors as nonexecuting cache refusal
    When I send a cache capability conversation with:
      | mode    | negative |
      | single  | true     |
      | status  | <status> |
      | type    | invalid_request_error |
      | code    | <code>   |
      | message | <message> |
      | param   | <param>  |
    Then the cache capability observations are:
      | requests             | 1      |
      | controls             | [true] |
      | no_unsupported       | true   |
      | failed_unknown       | true   |
      | no_completed_items   | true   |
    Examples:
      | status | code                                       | message                                               | param                    |
      | 400    | invalid_parameter                          | invalid input                                         | input                    |
      | 400    | invalid_parameter                          | invalid cache ttl                                     | prompt_cache_options.ttl |
      | 400    | invalid_parameter                          | invalid mode                                          | prompt_cache_options     |
      | 400    | invalid_parameter                          | prompt_cache_options is not supported on this model   | model                    |
      | 403    | invalid_parameter                          | prompt_cache_options is not supported on this model   | prompt_cache_options     |
      | 401    | unauthorized                               | prompt_cache_options is not supported on this model   | prompt_cache_options     |
      | 429    | subscription_sharing_usage_limit_exceeded   | prompt_cache_options is not supported on this model   | prompt_cache_options     |
      | 400    | model_not_found                            | model unavailable                                     | model                    |
      | 400    | policy_violation                           | prompt_cache_options is not supported on this model   | prompt_cache_options     |
      | 400    | context_length_exceeded                    | full                                                  | input                    |

  Scenario Outline: Uncertain streams and network failures retain controls on ordinary retries
    When I send a cache capability conversation with:
      | mode    | <mode>   |
      | single  | false    |
      | status  | 400      |
      | type    | invalid_request_error |
      | code    | invalid_parameter |
      | message | prompt_cache_options is not supported on this model |
      | param   | prompt_cache_options |
    Then the cache capability observations are:
      | requests             | <requests> |
      | controls             | <controls> |
      | no_unsupported       | true       |
      | failed_unknown       | true       |
      | no_completed_items   | true       |
    Examples:
      | mode          | requests | controls          |
      | failed-stream | 1        | [true]            |
      | cut-stream    | 3        | [true,true,true]  |
      | network       | 3        | [true,true,true]  |

  Scenario Outline: A compatibility request cannot renew the deadline or defeat cancellation
    When I send a cache capability conversation with:
      | mode    | <mode> |
      | single  | false  |
      | status  | 400    |
      | type    | invalid_request_error |
      | code    | invalid_parameter |
      | message | prompt_cache_options is not supported on this model |
      | param   | absent |
      | budget  | 600    |
    Then the cache capability observations are:
      | outcomes        | <outcomes>         |
      | requests        | 2                  |
      | controls        | [true,false]       |
      | bounded         | true               |
      | sockets_closed  | true               |
      | failed_unknown  | true               |
    Examples:
      | mode     | outcomes                       |
      | deadline | ["provider/unavailable"]       |
      | cancel   | ["cancel/SIGINT"]              |
