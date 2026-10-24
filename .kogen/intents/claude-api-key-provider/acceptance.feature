Feature: Native Claude API-key roles without provider fallback
  Local fixtures prove plumbing and custody, not live Anthropic access or visual interpretation.

  Scenario: Save a private Anthropic key and list four providers offline
    When I exercise native Claude "login" with:
      """
      {}
      """
    Then the native Claude observations include:
      | exits          | [0,0,4,4] |
      | saved          | {"provider":"anthropic","api_key":"SYNTHETIC_ANTHROPIC_PRIVATE_KEY"} |
      | status         | "anthropic: key saved (not verified)" |
      | modes          | [384,448,448] |
      | previous_kept  | true |
      | providers      | ["chatgpt","supergrok","opencode-go","anthropic"] |
      | requests       | 0 |
      | safe           | true |

  Scenario: A borrowed environment key is not a native login
    When I exercise native Claude "missing-login" with:
      """
      {}
      """
    Then the native Claude observations include:
      | exit           | 4 |
      | login_guidance | true |
      | requests       | 0 |
      | safe           | true |

  Scenario Outline: Select documented Claude models and the initial Kogen effort subset independently
    When I exercise native Claude "config" with:
      """
      {"model":"<model>","effort":"<effort>","provider":"<provider>","workers":<workers>}
      """
    Then the native Claude observations include:
      | outcome | "<outcome>" |
    Examples:
      | provider  | model                | effort | workers | outcome |
      | anthropic | claude-opus-5-5      | low    | false   | parsed |
      | anthropic | claude-opus-5-5      | medium | false   | parsed |
      | anthropic | claude-opus-5-5      | high   | false   | parsed |
      | anthropic | claude-opus-5-5      | max    | true    | parsed |
      | anthropic | claude-sonnet-5-5    | low    | true    | parsed |
      | anthropic | claude-sonnet-5-5    | medium | false   | parsed |
      | anthropic | claude-sonnet-5-5    | high   | false   | parsed |
      | anthropic | claude-sonnet-5-5    | max    | true    | parsed |
      | anthropic | claude-invented     | high   | false   | refused |
      | anthropic | claude-opus-5-5      | xhigh  | true    | refused |
      | unknown   | claude-opus-5-5      | high   | false   | refused |
      | omitted   | gpt-6.1-sol          | high   | false   | parsed |

  Scenario: Replay parallel tools and opaque thinking with honest Anthropic usage
    When I exercise native Claude "transport" with:
      """
      {"model":"claude-opus-5-5","effort":"high"}
      """
    Then the native Claude observations include:
      | outcomes | ["completed","completed","completed"] |
      | requests | 3 |
      | wire     | true |
      | usage    | {"input":130,"cached":20,"output":12,"reasoning":null} |
      | writes   | [10,null,null] |
      | unknown_effective_effort | true |
      | safe     | true |

  Scenario: Missing provider counts stay unknown
    When I exercise native Claude "transport" with:
      """
      {"usage":{}}
      """
    Then the native Claude observations include:
      | outcomes | ["completed","completed","completed"] |
      | usage    | {"input":null,"cached":null,"output":null,"reasoning":null} |
      | writes   | [null,null,null] |

  Scenario: Accept complete end-turn text without inventing a tool
    When I exercise native Claude "transport" with:
      """
      {"completion":"end_turn"}
      """
    Then the native Claude observations include:
      | outcomes | ["completed"] |
      | text     | "Complete local answer" |
      | calls    | 0 |
      | requests | 1 |

  Scenario Outline: A non-success response never exposes even an earlier valid tool
    When I exercise native Claude "transport" with:
      """
      {"completion":"<completion>"}
      """
    Then the native Claude observations include:
      | completed | false |
      | calls     | 0 |
      | safe      | true |
    Examples:
      | completion |
      | malformed |
      | max_tokens |
      | refusal |
      | pause_turn |
      | stop_sequence |
      | model_context_window_exceeded |
      | empty |
      | duplicate-id |
      | stream-error |

  Scenario Outline: Definite HTTP failures stop without fallback or credential leakage
    When I exercise native Claude "transport" with:
      """
      {"status":<status>,"type":"<type>"}
      """
    Then the native Claude observations include:
      | outcomes | ["<outcome>"] |
      | requests | 1 |
      | calls    | 0 |
      | safe     | true |
      | only_anthropic | true |
    Examples:
      | status | type                  | outcome |
      | 400    | invalid_request_error | provider/refused |
      | 401    | authentication_error  | provider/login |
      | 402    | billing_error         | provider/refused |
      | 403    | permission_error      | provider/refused |
      | 404    | not_found_error       | provider/model_unavailable |
      | 413    | request_too_large     | provider/context_too_long |

  Scenario Outline: Transient or cut responses remain bounded by the logical deadline
    When I exercise native Claude "transport" with:
      """
      <settings>
      """
    Then the native Claude observations include:
      | completed | false |
      | calls | 0 |
      | bounded | true |
      | safe | true |
      | only_anthropic | true |
    Examples:
      | settings |
      | {"status":429,"type":"rate_limit_error","budget":300} |
      | {"status":529,"type":"overloaded_error","budget":300} |
      | {"completion":"cut","budget":300} |
      | {"hold":true,"budget":300} |

  Scenario: Guard the complete Anthropic request at the unchanged byte boundary
    When I exercise native Claude "budget" with:
      """
      {}
      """
    Then the native Claude observations include:
      | body_is_messages | true |
      | bytes | [524287,524288,524289] |
      | fits | [true,true,false] |
      | reserve | [131072,131072,131072] |

  Scenario: Refuse unqualified typed images before inference with an honest handoff
    When I exercise native Claude "transport" with:
      """
      {"image":true}
      """
    Then the native Claude observations include:
      | outcomes | ["provider/unsupported_capability"] |
      | requests | 0 |
      | external_handoff | true |
      | calls | 0 |

  Scenario Outline: Mix families through questions approval blocked review and explicit resume
    When I run the native Claude mixed journey with roles "<roles>"
    Then the native Claude observations include:
      | exits | [5,0,1,0] |
      | question | true |
      | blocked | true |
      | same_reviewer | true |
      | fresh_gate | true |
      | history | true |
      | one_commit | true |
      | candidate | true |
      | independent | true |
      | approval_consumed | true |
      | safe | true |
      | wire | true |
      | routes_correct | true |
      | usage_retained | true |
    Examples:
      | roles |
      | anthropic,opencode-go,supergrok |
      | supergrok,anthropic,opencode-go |
      | chatgpt,opencode-go,anthropic |
      | anthropic,anthropic,anthropic |

  Scenario: Explain API billing private login and installed qualification honestly
    When I read native Claude guidance
    Then native Claude guidance includes:
      | kogen provider login anthropic |
      | claude-opus-5-5 |
      | claude-sonnet-5-5 |
      | key saved (not verified) |
      | API |
      | subscription |
      | qualification |
      | ~/.kogen/credentials/anthropic.json |
