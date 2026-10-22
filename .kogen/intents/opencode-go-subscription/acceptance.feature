Feature: OpenCode Go subscription and honest prefix reuse
  Background:
    Given the Go subscription fixture inputs:
      """
      {
        "key":"oc_sk_SYNTHETIC_KOGEN_GO_ONLY",
        "borrowed":"BORROWED_OPERATOR_OR_HARNESS_KEY_NEVER_USE",
        "policy":"STABLE_POLICY_AUTHORITY",
        "contract":"STABLE_CONTRACT_AUTHORITY",
        "model":"kimi-k3",
        "effort":"high",
        "raw":{"role":"assistant","content":null,"reasoning":"SYNTHETIC_PRIVATE_REASONING Δ","reasoning_details":[{"type":"reasoning.text","index":0,"text":"SYNTHETIC_PRIVATE_REASONING Δ","vendor_extension":{"keep":[2,1]}}],"tool_calls":[{"id":"call_read","type":"function","function":{"name":"read_file","arguments":"{\"path\":\"app.txt\"}"}}]},
        "usage":{"prompt_tokens":100,"prompt_tokens_details":{"cached_tokens":20},"completion_tokens":10,"completion_tokens_details":{"reasoning_tokens":4}}
      }
      """

  Scenario: Own stdin login is private, offline and preserves prior bytes on empty input
    When I exercise the Go subscription "login"
    Then the Go subscription observations include:
      | login_exit | 0 |
      | login_line | "opencode-go: key saved (not verified)" |
      | list_exit | 0 |
      | list_line | "opencode-go: key saved (not verified)" |
      | empty_exit | 4 |
      | empty_message | true |
      | previous_bytes_kept | true |
      | credential | {"provider":"opencode-go","api_key":"oc_sk_SYNTHETIC_KOGEN_GO_ONLY"} |
      | modes | [384,448,448] |
      | requests | 0 |
      | no_public_secret | true |

  Scenario: An environment or borrowed harness key cannot replace Kogen login
    When I exercise the Go subscription "missing-login"
    Then the Go subscription observations include:
      | exit | 4 |
      | login_guidance | true |
      | requests | 0 |
      | no_public_secret | true |

  Scenario: Go-only native work keeps source, tools, independent review and saved review continuity
    When I exercise the Go subscription "workflow"
    Then the Go subscription observations include:
      | exits | [5,0,0,1,0] |
      | phases | ["shape","shape","refine","refine","build","build","review","review","review"] |
      | wire_and_replay | true |
      | source_retrieval | true |
      | reviewer_independent | true |
      | review_contains_candidate | true |
      | prior_result_unchanged | true |
      | blocked_without_commit | true |
      | committed_candidate | true |
      | one_commit | true |
      | usage_exit | 0 |
      | go_usage_present | true |
      | no_public_secret | true |

  Scenario Outline: The native Go adapter preserves raw reasoning and requested effort
    When I exercise the Go subscription "transport" with:
      | effort | <effort> |
    Then the Go subscription observations include:
      | outcomes | ["completed","completed","completed"] |
      | requests | 3 |
      | wire_and_replay | true |
      | effort_wire | <wire> |
      | normalized_usage | {"input":100,"cached":20,"output":10,"reasoning":4} |
      | unknown_write_and_effort | true |
      | no_public_secret | true |
    Examples:
      | effort | wire |
      | high | "high" |
      | default | null |

  Scenario Outline: Go refuses permanent failures without another route or key refresh
    When I exercise the Go subscription "transport" with:
      | status | <status> |
      | code | <code> |
    Then the Go subscription observations include:
      | outcomes | <outcomes> |
      | requests | <requests> |
      | only_go_route | true |
      | failed_unknown | true |
      | no_public_secret | true |
    Examples:
      | status | code | outcomes | requests |
      | 401 | unauthorized | ["provider/login"] | 1 |
      | 402 | insufficient_credits | ["provider/refused"] | 1 |
      | 403 | permission_denied | ["provider/refused"] | 1 |
      | 400 | model_not_found | ["provider/model_unavailable"] | 1 |
      | 429 | rate_limit_exceeded | ["provider/unavailable"] | 3 |

  Scenario Outline: Invalid completions cannot execute a partial tool batch
    When I exercise the Go subscription "transport" with:
      | completion | <completion> |
    Then the Go subscription observations include:
      | outcomes | ["provider/invalid_response"] |
      | no_completed_items | true |
      | no_tool_effect | true |
      | only_go_route | true |
    Examples:
      | completion |
      | malformed-tool |
      | length |
      | missing-choice |

  Scenario: Images are refused rather than silently turned into text
    When I exercise the Go subscription "transport" with:
      | image | true |
    Then the Go subscription observations include:
      | outcomes | ["provider/unsupported_capability"] |
      | requests | 0 |
      | no_completed_items | true |
      | external_image_handoff | true |

  Scenario: A held Go request respects the same logical wait boundary
    When I exercise the Go subscription "transport" with:
      | hold | true |
      | budget | 300 |
    Then the Go subscription observations include:
      | outcomes | ["provider/unavailable"] |
      | bounded | true |
      | no_completed_items | true |
      | sockets_closed | true |

  Scenario: Rendered Go bodies retain the exact inclusive context budget
    When I exercise the Go subscription "budget"
    Then the Go subscription observations include:
      | body_is_chat | true |
      | bytes | [524287,524288,524289] |
      | fits | [true,true,false] |
      | reserve | [131072,131072,131072] |

  Scenario Outline: Presets are complete explicit parseable choices rather than automatic fallback
    When I parse the Go subscription preset "<file>"
    Then the Go subscription observations include:
      | roles | <roles> |
      | workers | false |
    Examples:
      | file | roles |
      | opencode-go-only | [["opencode-go","kimi-k3","high"],["opencode-go","kimi-k3","high"],["opencode-go","kimi-k3","high"]] |
      | supergrok-only | [["supergrok","grok-4.7","high"],["supergrok","grok-4.7","medium"],["supergrok","grok-4.7","high"]] |
      | three-subscriptions | [["chatgpt","gpt-6.1-sol","high"],["opencode-go","kimi-k3","high"],["supergrok","grok-4.7","high"]] |
      | supergrok-opencode-go | [["supergrok","grok-4.7","high"],["opencode-go","kimi-k3","high"],["supergrok","grok-4.7","high"]] |

  Scenario Outline: Unqualified Go models and efforts are rejected before inference
    When I exercise the Go subscription "config" with:
      | model | <model> |
      | effort | <effort> |
    Then the Go subscription observations include:
      | outcome | "environment/project_config_invalid" |
      | requests | 0 |
    Examples:
      | model | effort |
      | gpt-6.1-sol | high |
      | grok-4.7 | high |
      | claude-haiku-5-5 | high |
      | kimi-k3 | xhigh |

  Scenario Outline: SuperGrok routing is stable and a named unsupported key has a bounded fallback
    When I exercise the Go subscription "supergrok-cache" with:
      | reject_key | <reject> |
    Then the Go subscription observations include:
      | outcomes | ["completed","completed","completed"] |
      | requests | <requests> |
      | key_flags | <flags> |
      | stable_routing | true |
      | cache_only_fallback | true |
      | encrypted_replay | true |
      | no_public_secret | true |
    Examples:
      | reject | requests | flags |
      | false | 3 | [true,true,true] |
      | true | 5 | [true,false,false,true,false] |

  Scenario: ChatGPT keeps the exact recognized rejection compatibility without losing replay
    When I send a cache capability conversation with:
      | mode | success |
      | status | 400 |
      | type | invalid_request_error |
      | code | invalid_parameter |
      | param | absent |
      | message | prompt_cache_options is not supported on this model |
      | single | false |
    Then the cache capability observations are:
      | outcomes | ["completed","completed"] |
      | requests | 3 |
      | controls | [true,false,false] |
      | fallback_preserves_body | true |
      | later_preserves_replay | true |
      | honest_attempts | true |
      | exact_completed_items | true |

  Scenario: Maintained guidance states the security and qualification limits
    When I read the Go subscription guidance
    Then the Go subscription guidance contains:
      | kogen provider login opencode-go |
      | x-opencode-session |
      | prompt_cache_key |
      | kimi-k3 |
      | Extra usage |
      | auto-recharge |
      | not verified |
      | 524288 |
      | 131072 |
      | configuration-first |
      | unlimited |
      | UNKNOWN |
