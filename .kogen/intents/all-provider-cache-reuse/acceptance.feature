Feature: Effective route-specific reuse without weakening custody
  Background:
    Given the all-provider cache fixture authority:
      """
      {"policy":"PRIVATE_POLICY_KEEP_COMPLETE","contract":"AUTHORITATIVE_CONTRACT_KEEP_COMPLETE","tool_result":"PRIVATE_EXACT_TOOL_RESULT","opaque":"OPAQUE_SIGNED_PROVIDER_FIXTURE","usage":{"input":130,"cached":20,"write":10,"output":12},"limit":524288,"reserve":131072}
      """

  Scenario Outline: Each actual adapter keeps stable policy tools order and private replay
    When I exercise all-provider cache "reuse" with:
      """
      {"provider":"<provider>","model":"<model>","effort":"<effort>","route":"<route>"}
      """
    Then all-provider cache observations include:
      | completed | true |
      | wire | true |
      | stable | true |
      | replay | true |
      | isolated | true |
      | restored | true |
      | once | true |
      | usage | true |
      | unknown | true |
      | safe | true |
    Examples:
      | provider | model | effort | route |
      | chatgpt | gpt-6.1-sol | high | /v1/responses |
      | supergrok | grok-4.7 | high | /v1/responses |
      | opencode-go | kimi-k3 | high | /inference/go/openai/v1/chat/completions |
      | opencode-go | kimi-k3 | default | /inference/go/openai/v1/chat/completions |
      | anthropic | claude-sonnet-5-5 | medium | /v1/messages |
      | anthropic | claude-opus-5-5 | high | /v1/messages |

  Scenario Outline: A definite named-key rejection permits one sticky compatibility retry
    When I exercise all-provider cache "refusal" with:
      """
      {"provider":"<provider>","model":"<model>","effort":"high","route":"/v1/responses","status":400,"param":"prompt_cache_key","type":"invalid_request_error","code":"<code>","message":"prompt_cache_key is not supported on this model","single":<single>}
      """
    Then all-provider cache observations include:
      | completed | true |
      | requests | 3 |
      | fallback | true |
      | replay | true |
      | once | true |
      | failed_unknown | true |
      | safe | true |
    Examples:
      | provider | model | code | single |
      | chatgpt | gpt-6.1-sol | invalid_parameter | false |
      | chatgpt | gpt-6.1-sol | invalid_parameter | true |
      | chatgpt | gpt-6.1-sol | unknown_parameter | false |
      | chatgpt | gpt-6.1-sol | unsupported_parameter | false |
      | supergrok | grok-4.7 | unsupported_parameter | false |

  Scenario Outline: Unrelated or uncertain refusals are not cache support
    When I exercise all-provider cache "refusal" with:
      """
      {"provider":"<provider>","model":"<model>","effort":"high","route":"<route>","status":<status>,"param":<param>,"type":"invalid_request_error","code":"invalid_parameter","message":"<message>"}
      """
    Then all-provider cache observations include:
      | completed | false |
      | requests | 1 |
      | failed_unknown | true |
      | once | true |
      | safe | true |
    Examples:
      | provider | model | route | status | param | message |
      | chatgpt | gpt-6.1-sol | /v1/responses | 400 | null | prompt_cache_key is not supported on this model |
      | chatgpt | gpt-6.1-sol | /v1/responses | 400 | "absent" | prompt_cache_key is not supported on this model |
      | chatgpt | gpt-6.1-sol | /v1/responses | 400 | "model" | prompt_cache_key is not supported on this model |
      | chatgpt | gpt-6.1-sol | /v1/responses | 400 | "prompt_cache_key" | model unavailable |
      | chatgpt | gpt-6.1-sol | /v1/responses | 401 | "prompt_cache_key" | prompt_cache_key is not supported on this model |
      | chatgpt | gpt-6.1-sol | /v1/responses | 403 | "prompt_cache_key" | prompt_cache_key is not supported on this model |
      | supergrok | grok-4.7 | /v1/responses | 400 | "prompt_cache_key" | prompt_cache_key is not supported on this model |
      | supergrok | grok-4.7 | /v1/responses | 403 | "prompt_cache_key" | account forbidden |
      | opencode-go | kimi-k3 | /inference/go/openai/v1/chat/completions | 403 | null | account forbidden |
      | anthropic | claude-sonnet-5-5 | /v1/messages | 400 | "cache_control" | invalid request, cause not established historically |

  Scenario Outline: Adapted cache controls count in the unchanged complete request ceiling
    When I exercise all-provider cache "budget" with:
      """
      {"provider":"<provider>","model":"<model>","effort":"high","route":"<route>"}
      """
    Then all-provider cache observations include:
      | bytes | [524287,524288,524289] |
      | fits | [true,true,false] |
      | reserves | [131072,131072,131072] |
      | requests | 1 |
      | outcomes | ["completed","candidate/context_budget_exceeded"] |
    Examples:
      | provider | model | route |
      | chatgpt | gpt-6.1-sol | /v1/responses |
      | supergrok | grok-4.7 | /v1/responses |
      | opencode-go | kimi-k3 | /inference/go/openai/v1/chat/completions |
      | anthropic | claude-sonnet-5-5 | /v1/messages |

  Scenario: Installed native roles keep exact approval and independent review
    When I run the all-provider installed scripted journey
    Then all-provider cache observations include:
      | exits | [5,0,0] |
      | requests | 6 |
      | cache_wiring | true |
      | exact_approval | true |
      | independent | true |
      | checks | true |
      | landed | true |
      | safe | true |

  Scenario Outline: The real-journey script is qualified locally before spending
    When I exercise the all-provider qualification script with "<outcome>" loopback providers
    Then all-provider cache observations include:
      | baseline | true |
      | guarded | true |
      | shape | true |
      | approved | true |
      | roles | true |
      | followups | <followups> |
      | status | "<status>" |
      | landed | <landed> |
      | refused | <refused> |
      | once | true |
      | safe | true |
    Examples:
      | outcome | followups | status | landed | refused |
      | complete | true | qualified | true | false |
      | refused | false | stopped-not-qualified | false | true |

  Scenario: Missing reviewer login stops qualification before inference
    When I exercise the all-provider qualification script with "missing-login" loopback providers
    Then all-provider cache observations include:
      | missing_login | true |
      | requests | 0 |
      | status | "stopped-not-qualified" |
