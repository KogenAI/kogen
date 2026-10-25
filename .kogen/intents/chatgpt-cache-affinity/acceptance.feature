Feature: ChatGPT official-route conversation cache affinity
  The supplied C3 numbers are external scoped evidence, not required savings or account qualification.
  The candidate changes only ChatGPT routing headers, not bodies, replay or authority.

  Background:
    Given the ChatGPT affinity wire expectations:
      """
      {"headers":["accept","authorization","connection","content-length","content-type","conversation_id","host","session_id"],"authorization":"Bearer fake-integration-access-token","route":"/v1/responses","model":"gpt-6.1-sol","build_effort":"medium","other_effort":"high","include":["reasoning.encrypted_content"],"forbidden":["prompt_cache_options","prompt_cache_retention","previous_response_id","conversation"],"exits":[5,5,0,4,0]}
      """

  Scenario: Route each native conversation without changing its lifecycle
    When I record the ChatGPT affinity CLI lifecycle
    Then the ChatGPT affinity observations are:
      | headers      | true |
      | stable       | true |
      | isolated     | true |
      | wire         | true |
      | replay       | true |
      | reset        | true |
      | retry_resume | true |
      | independent  | true |
      | authority    | true |

  Scenario: Retain affinity when the body key is explicitly unsupported
    When I record ChatGPT affinity compatibility "key"
    Then the ChatGPT affinity observations are:
      | headers      | true |
      | fallback     | true |
      | replay       | true |
      | accounting   | true |
      | outcomes     | ["completed","completed"] |
      | requests     | 3 |
      | statuses     | ["unsupported","unsupported","unsupported"] |

  Scenario: Do not invent a fallback for a session header refusal
    When I record ChatGPT affinity compatibility "header"
    Then the ChatGPT affinity observations are:
      | headers      | true |
      | accounting   | true |
      | outcomes     | ["provider/refused"] |
      | requests     | 1 |
      | statuses     | ["requested"] |

  Scenario Outline: Preserve delivered caching on other provider wires
    Given the all-provider cache fixture authority:
      """
      {"policy":"PRIVATE_POLICY_KEEP_COMPLETE","contract":"AUTHORITATIVE_CONTRACT_KEEP_COMPLETE","tool_result":"PRIVATE_EXACT_TOOL_RESULT","opaque":"OPAQUE_SIGNED_PROVIDER_FIXTURE","usage":{"input":130,"cached":20,"write":10,"output":12},"limit":524288,"reserve":131072}
      """
    When I exercise all-provider cache "reuse" with:
      """
      {"provider":"<provider>","model":"<model>","effort":"high","route":"<route>"}
      """
    Then all-provider cache observations include:
      | completed | true |
      | wire      | true |
      | stable    | true |
      | replay    | true |
      | isolated  | true |
      | restored  | true |
      | once      | true |
      | usage     | true |
      | unknown   | true |
      | safe      | true |

    Examples:
      | provider    | model             | route                                     |
      | supergrok   | grok-4.7          | /v1/responses                             |
      | opencode-go | kimi-k3           | /inference/go/openai/v1/chat/completions    |
      | anthropic   | claude-sonnet-5-5  | /v1/messages                              |
