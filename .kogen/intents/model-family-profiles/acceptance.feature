Feature: Official model family policies without restricting experiments

  Scenario: Offline catalog publishes exact profiles rather than provider-wide claims
    When I inspect the model family catalog as JSON
    Then the model family JSON contains:
      """
      {"schema_version":1,"profiles":[
        {"id":"chatgpt-sol-6-1","provider":"chatgpt","model":"gpt-6.1-sol","route":"https://api.openai.com/v1/responses","documented_efforts":["low","medium","high","xhigh","max"],"limits":{"context_tokens":1050000,"max_input_tokens":922000,"max_output_tokens":128000,"input_bytes":524288,"reserve_tokens":131072},"settings":{"wire":"responses","stream":true,"effort":"reasoning.effort","reasoning":"encrypted","output":"provider-default","tools":"auto","schema":"native","replay":"responses-items","cache":"prompt_cache_key","images":"experimental"},"qualifications":[{"role":"shape","effort":"high","evidence_ids":["go-live-2026-10-24"]},{"role":"build","effort":"medium","evidence_ids":["go-live-2026-10-24"]},{"role":"review","effort":"high","evidence_ids":["native-go-sol-review-2026-10-24"]}],"evidence":[{"id":"go-live-2026-10-24","source_tree":"7e708f1c81a8d9d68956e422f2935b3959fc7639","archive_sha256":"eaa60cc4383f25180542bf97f572b653a773dbc46538a48f816e519c0b76beee","landed_commit":"bd800096ab51c34a8a4ce4fca7696122f0152b5b"},{"id":"native-go-sol-review-2026-10-24","provider_tree":"ea5efa099be455516ed87e6ebc1840874f408b72","baseline_commit":"f38e488778c198e57d90ca1fc17a13c664168919","runs":[{"run_id":"553c44bd","runtime_version":"kogen d0bc4af0 (2026-10-24)","runtime_sha256":"fe374affa7b4b94ec67299dfe3639dd21b9e0e2fab194fe5f713b08480f5f536","start_head":"d0bc4af0804876eea2724b412451c1cdb7028248","landed_commit":"687f140700426b3b4ad3e3eae7f1d854762dad31","review_tree":"0341c848eaefb29fecd932ecb8f1f30d4537b12f","review_verdict":"approve","review_sha256":"9e559a179585b1604e5c429357a5b03fcfb9f33fb2abacc83fc0469ce11f9fe6"},{"run_id":"b515525a","runtime_version":"kogen 687f1407 (2026-10-24)","runtime_sha256":"c0e21b0f7ef17cea2cee1eb5cf9a99bb85ae6bd6fc1eff4fa74a12f893a1a092","start_head":"687f140700426b3b4ad3e3eae7f1d854762dad31","landed_commit":"f38e488778c198e57d90ca1fc17a13c664168919","review_tree":"3f6f701def347f08f36519db434132ef1304aea3","review_verdict":"approve","review_sha256":"2464a2a68b05e63508745a5a65888fd0554f67347d7c92eaa163492b13a15c1c"}]}]},
        {"id":"anthropic-sonnet-5-5","provider":"anthropic","model":"claude-sonnet-5-5","route":"https://api.anthropic.com/v1/messages","documented_efforts":["low","medium","high","xhigh","max"],"limits":{"context_tokens":1000000,"max_input_tokens":null,"max_output_tokens":128000,"input_bytes":524288,"reserve_tokens":131072},"settings":{"wire":"messages","stream":true,"effort":"output_config.effort","reasoning":"adaptive","output":"max_tokens","tools":"auto","schema":"input_schema","replay":"signed-messages","cache":"ephemeral-breakpoints","images":"unsupported"},"qualifications":[{"role":"review","effort":"medium","evidence_ids":["go-live-2026-10-24"]}],"evidence":[{"id":"go-live-2026-10-24","source_tree":"7e708f1c81a8d9d68956e422f2935b3959fc7639","archive_sha256":"eaa60cc4383f25180542bf97f572b653a773dbc46538a48f816e519c0b76beee","landed_commit":"bd800096ab51c34a8a4ce4fca7696122f0152b5b"}]}
      ]}
      """

  Scenario: Human list preserves offline login status and explains experimentation
    When I inspect the model family catalog as text
    Then the model family text includes:
      | chatgpt: not signed in |
      | supergrok: not signed in |
      | opencode-go: not signed in |
      | anthropic: not signed in |
      | gpt-6.1-sol |
      | claude-sonnet-5-5 |
      | shape |
      | build |
      | review |
      | medium |
      | high |
      | experimental |

  Scenario Outline: Qualified text and tool selections keep their exact request policy
    When I exercise the model family selection:
      """
      {"provider":"<provider>","model":"<model>","effort":"<effort>","role":"<role>"}
      """
    Then the model family report contains:
      """
      {"requests":2,"calls":[1,0],"errors":[],"transport":{"wire":true,"replay":true,"schema":true,"cache":true,"auth":true,"usage":true},"compatibility":[{"status":"supported","profile":"<profile>","role":"<role>","provider":"<provider>","model":"<model>","effort":"<effort>"},{"status":"supported","profile":"<profile>"}]}
      """
    Examples:
      | provider  | model             | effort | role   | profile                |
      | chatgpt   | gpt-6.1-sol       | high   | shape  | chatgpt-sol-6-1         |
      | chatgpt   | gpt-6.1-sol       | medium | build  | chatgpt-sol-6-1         |
      | chatgpt   | gpt-6.1-sol       | high   | review | chatgpt-sol-6-1         |
      | anthropic | claude-sonnet-5-5 | medium | review | anthropic-sonnet-5-5    |

  Scenario Outline: Configurable strings do not silently inherit official compatibility
    When I exercise the model family selection:
      """
      {"provider":"<provider>","model":"<model>","effort":"<effort>","role":"<role>"}
      """
    Then the model family report contains:
      """
      {"requests":2,"calls":[1,0],"errors":[],"transport":{"wire":true,"replay":true,"schema":true,"cache":true,"auth":true,"usage":true},"compatibility":[{"status":"experimental","profile":<profile>,"role":"<role>","provider":"<provider>","model":"<model>","effort":"<effort>"},{"status":"experimental","profile":<profile>}]}
      """
    Examples:
      | provider          | model                     | effort       | role   | profile                     |
      | chatgpt           | gpt-6.1-sol               | medium       | review | "chatgpt-sol-6-1"           |
      | chatgpt           | gpt-6.1-sol               | try-anything | build  | "chatgpt-sol-6-1"           |
      | chatgpt           | gpt-6.1-sol-next          | medium       | build  | null                        |
      | anthropic         | claude-sonnet-5-5         | high         | build  | "anthropic-sonnet-5-5"      |
      | anthropic         | claude-sonnet-5-5-next    | medium       | review | null                        |
      | opencode-go       | kimi-k3.1-pro             | high         | build  | null                        |
      | supergrok         | grok-4.7                  | high         | review | null                        |
      | openai-compatible | gpt-6.1-sol               | medium       | build  | null                        |
      | openai-compatible | qwen-coder                | default      | build  | null                        |

  Scenario: Omitted role selections retain the ChatGPT Shape default
    When I exercise the model family selection:
      """
      {"provider":"chatgpt","model":"unused","effort":"unused","role":"shape","mode":"defaults"}
      """
    Then the model family report contains:
      """
      {"requests":2,"transport":{"wire":true,"replay":true,"schema":true,"cache":true,"auth":true,"usage":true},"compatibility":[{"status":"supported","profile":"chatgpt-sol-6-1","role":"shape","model":"gpt-6.1-sol","effort":"high"},{"status":"supported"}]}
      """

  Scenario: A test-route override cannot inherit installed production qualification
    When I exercise the model family selection:
      """
      {"provider":"chatgpt","model":"gpt-6.1-sol","effort":"medium","role":"build","seam":true}
      """
    Then the model family report contains:
      """
      {"requests":2,"calls":[1,0],"errors":[],"compatibility":[{"status":"experimental","profile":"chatgpt-sol-6-1"},{"status":"experimental","profile":"chatgpt-sol-6-1"}]}
      """

  Scenario: An experimental provider refusal stops once with an actionable source selector
    When I exercise the model family selection:
      """
      {"provider":"supergrok","model":"no-such-model","effort":"high","role":"review","mode":"reject"}
      """
    Then the model family report contains:
      """
      {"requests":1,"calls":[],"compatibility":[{"status":"experimental","profile":null,"role":"review","provider":"supergrok","model":"no-such-model","effort":"high"}]}
      """
    And the model family error includes:
      | model not found |
      | review |
      | supergrok |
      | no-such-model |
      | experimental |
      | .kogen/project.yaml |
      | models.review |

  Scenario Outline: The full serialized request guard remains inclusive without clipping
    When I exercise the model family selection:
      """
      {"provider":"<provider>","model":"<model>","effort":"<effort>","role":"<role>","mode":"budget"}
      """
    Then the model family report contains:
      """
      {"requests":2,"sizes":[524287,524288,524289],"errors":[{"code":"candidate/context_budget_exceeded","exit":1}]}
      """
    And the model family error includes:
      | 524289 |
      | 524288 |
      | 131072 |
    Examples:
      | provider  | model             | effort | role   |
      | chatgpt   | gpt-6.1-sol       | medium | build  |
      | anthropic | claude-sonnet-5-5 | medium | review |

  Scenario: Official text support does not enable Anthropic typed images
    When I exercise the model family selection:
      """
      {"provider":"anthropic","model":"claude-sonnet-5-5","effort":"medium","role":"review","image":true}
      """
    Then the model family report contains:
      """
      {"requests":0,"calls":[],"errors":[{"code":"provider/unsupported_capability","exit":4}]}
      """
    And the model family error includes:
      | images are unsupported |
      | external image preparation |
      | pixel-review handoff |
