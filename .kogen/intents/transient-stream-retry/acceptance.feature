Feature: Bounded transient stream retry
  Long Builds absorb transient stream failures without losing completed work or requiring
  an operator resume. These are synthetic local-provider reproductions, not live captures.
  Staged Intents, the Go rewrite, Studio and scheduled monitoring are not exercised or changed.

  Scenario: The reported ChatGPT overload recovers on the third attempt
    When I exercise transient stream retry with:
      """
      {"entry":"transport","provider":"chatgpt","event":"error","error":{"code":"server_is_overloaded","type":"service_unavailable_error","message":"Our servers are currently overloaded"},"failures":2}
      """
    Then the transient stream retry result is:
      """
      {"outcome":"ok","requests":3,"failed":2,"waits":[2,8]}
      """

  Scenario Outline: Recognized codes retain shared stream-envelope support
    When I exercise transient stream retry with:
      """
      {"entry":"transport","provider":"<provider>","event":"<event>","error":{"code":"<code>","message":"Our servers are currently overloaded"},"failures":1}
      """
    Then the transient stream retry result is:
      """
      {"outcome":"ok","requests":2,"failed":1,"waits":[2]}
      """
    Examples:
      | provider  | event           | code                                   |
      | chatgpt   | flat            | server_is_overloaded                   |
      | chatgpt   | response.failed | server_is_overloaded                   |
      | supergrok | error           | server_is_overloaded                   |
      | supergrok | flat            | server_is_overloaded                   |
      | supergrok | response.failed | server_is_overloaded                   |
      | chatgpt   | error           | server_error                           |
      | chatgpt   | error           | rate_limit_exceeded                    |
      | chatgpt   | error           | subscription_sharing_usage_unavailable  |
      | chatgpt   | error           | subscription_sharing_user_unavailable   |

  Scenario Outline: The exact codeless SuperGrok generation failure recovers
    When I exercise transient stream retry with:
      """
      {"entry":"transport","provider":"supergrok","event":"<event>","error":<error>,"failures":1}
      """
    Then the transient stream retry result is:
      """
      {"outcome":"ok","requests":2,"failed":1,"waits":[2]}
      """
    Examples:
      | event           | error                                                                                   |
      | error           | {"message":"Internal error during token generation"}                                   |
      | flat            | {"message":"Internal error during token generation"}                                   |
      | response.failed | {"message":"Internal error during token generation"}                                   |
      | error           | {"code":null,"type":null,"message":"Internal error during token generation"}           |
      | error           | {"code":"","type":"","message":"Internal error during token generation"}               |

  Scenario Outline: Unknown or non-transient failures are not guessed transient
    When I exercise transient stream retry with:
      """
      {"entry":"transport","provider":"<provider>","event":"<event>","error":<error>,"failures":1}
      """
    Then the transient stream retry result is:
      """
      {"outcome":"provider/<reason>","requests":1,"failed":1,"diagnostics":<diagnostics>}
      """
    Examples:
      | provider  | event               | error                                                                                                                       | reason           | diagnostics                                                                                                                |
      | supergrok | error               | {"code":"unknown_capacity","type":"service_unavailable_error","message":"Internal error during token generation"}         | refused          | {"code":"unknown_capacity","type":"service_unavailable_error","event_kind":"error"}                                    |
      | supergrok | error               | {"type":"invalid_request_error","message":"Internal error during token generation"}                                       | refused          | {"type":"invalid_request_error","event_kind":"error"}                                                                    |
      | supergrok | error               | {"code":{"bad":"value"},"message":"Internal error during token generation"}                                              | refused          | {"event_kind":"error"}                                                                                                     |
      | supergrok | error               | {"type":"service_unavailable_error","message":"unknown overload"}                                                         | refused          | {"type":"service_unavailable_error","event_kind":"error"}                                                                |
      | supergrok | error               | {"message":"Internal error during token generation later"}                                                                 | refused          | {"event_kind":"error"}                                                                                                     |
      | chatgpt   | error               | {"message":"Internal error during token generation"}                                                                       | refused          | {"event_kind":"error"}                                                                                                     |
      | chatgpt   | flat                | {"code":"unknown_capacity","message":"Our servers are currently overloaded"}                                              | refused          | {"code":"unknown_capacity","event_kind":"error"}                                                                         |
      | chatgpt   | response.failed     | {"code":"subscription_sharing_usage_limit_exceeded","message":"Our servers are currently overloaded"}                     | usage_limit      | {"code":"subscription_sharing_usage_limit_exceeded","event_kind":"response.failed"}                                      |
      | chatgpt   | response.failed     | {"code":"model_not_found","message":"Our servers are currently overloaded"}                                               | model_unavailable| {"code":"model_not_found","event_kind":"response.failed"}                                                                |
      | chatgpt   | response.failed     | {"code":"context_length_exceeded","message":"Our servers are currently overloaded"}                                       | context_too_long | {"code":"context_length_exceeded","event_kind":"response.failed"}                                                        |
      | supergrok | response.incomplete | {"message":"Internal error during token generation"}                                                                       | refused          | {"event_kind":"response.incomplete"}                                                                                       |

  Scenario: Exhaustion retains the last overload diagnostics and unknown failed usage
    When I exercise transient stream retry with:
      """
      {"entry":"transport","provider":"chatgpt","event":"error","error":{"code":"server_is_overloaded","type":"service_unavailable_error","message":"Our servers are currently overloaded"},"failures":3}
      """
    Then the transient stream retry result is:
      """
      {"outcome":"provider/unavailable","requests":3,"failed":3,"waits":[2,8],"diagnostics":{"code":"server_is_overloaded","type":"service_unavailable_error","event_kind":"error"}}
      """

  Scenario: Codeless exhaustion does not invent a provider code
    When I exercise transient stream retry with:
      """
      {"entry":"transport","provider":"supergrok","event":"response.failed","error":{"message":"Internal error during token generation"},"failures":3}
      """
    Then the transient stream retry result is:
      """
      {"outcome":"provider/unavailable","requests":3,"failed":3,"waits":[2,8],"diagnostics":{"event_kind":"response.failed"}}
      """

  Scenario: Single-attempt mode does not enter transient backoff
    When I exercise transient stream retry with:
      """
      {"entry":"transport","provider":"chatgpt","event":"error","error":{"code":"server_is_overloaded","type":"service_unavailable_error","message":"Our servers are currently overloaded"},"failures":1,"single":true}
      """
    Then the transient stream retry result is:
      """
      {"outcome":"provider/unavailable","requests":1,"failed":1,"elapsed":[0,1500],"diagnostics":{"code":"server_is_overloaded","type":"service_unavailable_error","event_kind":"error"}}
      """

  Scenario: The existing absolute deadline expires inside overload backoff
    When I exercise transient stream retry with:
      """
      {"entry":"transport","provider":"chatgpt","event":"error","error":{"code":"server_is_overloaded","message":"Our servers are currently overloaded"},"failures":3,"budget":250}
      """
    Then the transient stream retry result is:
      """
      {"outcome":"provider/unavailable","requests":1,"failed":1,"elapsed":[200,1800]}
      """

  Scenario: Bridge cancellation interrupts overload backoff promptly
    When I exercise transient stream retry with:
      """
      {"entry":"transport","provider":"chatgpt","event":"error","error":{"code":"server_is_overloaded","message":"Our servers are currently overloaded"},"failures":3,"cancel":true}
      """
    Then the transient stream retry result is:
      """
      {"outcome":"cancel/SIGINT","requests":1,"failed":1,"elapsed":[150,1800]}
      """

  Scenario: An installed Build recovers without repeating tools and lands after Review
    When I exercise transient stream retry with:
      """
      {"entry":"build","event":"error","error":{"code":"server_is_overloaded","type":"service_unavailable_error","message":"Our servers are currently overloaded"},"failures":2}
      """
    Then the transient stream retry result is:
      """
      {"exit":0,"requests":5,"failed":2,"waits":[2,8]}
      """

  Scenario: An installed exhausted Build preserves valuable unlanded work and approval
    When I exercise transient stream retry with:
      """
      {"entry":"build","event":"error","error":{"code":"server_is_overloaded","type":"service_unavailable_error","message":"Our servers are currently overloaded"},"failures":3}
      """
    Then the transient stream retry result is:
      """
      {"exit":4,"requests":4,"failed":3,"waits":[2,8],"diagnostics":{"code":"server_is_overloaded","type":"service_unavailable_error","event_kind":"error"}}
      """
