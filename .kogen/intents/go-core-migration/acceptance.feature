Feature: Replace the whole maintained Kogen core with Go
  The candidate must implement maintained behavior natively, not wrap an old core.
  Stages are scoped progress under one approval; only final verification and review deliver.

  @go-local
  Scenario: Native installed local authority retains exact approval and data
    When I exercise Go migration local authority
    Then the Go migration authority observations are:
      | exits | [0,0,0,5,1,0,1] |
      | statuses | ["chatgpt: not signed in","supergrok: not signed in","opencode-go: key saved (not verified)","anthropic: key saved (not verified)"] |
      | hash_matches | true |
      | no_approval_on_card_or_mismatch | true |
      | approved_exact | true |
      | stale_refused | true |
      | custody | true |
      | modes | [384,384] |

  @go-shape
  Scenario: Native installed setup Shape approval and provider journeys
    When I run these Go migration installed specifications:
      | spec/features/01-project-setup.feature |
      | spec/features/02-shaping.feature |
      | spec/features/03-approval-and-build-start.feature |
      | spec/features/08-chatgpt.feature |
    Then every selected Go migration scenario passed exactly once

  @go-shape
  Scenario: Current shaping authority tools and four-provider contracts survive
    Given these accumulated scenarios are superseded by prompt caching:
      | opencode-go-subscription     | ChatGPT keeps the exact recognized rejection compatibility without losing replay |  |
      | prompt-cache-reuse-and-usage | Complete Shape authority and valid replay reach consecutive provider requests    |  |
      | prompt-cache-reuse-and-usage | Build and saved review preserve reuse without sharing authority                  |  |
      | prompt-cache-reuse-and-usage | Cache capability handling uses only safe necessary calls                         |  |
    And these accumulated scenarios are superseded by open model selection:
      | opencode-go-subscription | Unqualified Go models and efforts are rejected before inference                   |                                                      |
      | claude-api-key-provider  | Select documented Claude models and the initial Kogen effort subset independently | anthropic / claude-invented / high / false / refused |
      | claude-api-key-provider  | Select documented Claude models and the initial Kogen effort subset independently | anthropic / claude-opus-5-5 / xhigh / true / refused |
    When I run these accumulated Go migration contracts:
      | approval-card-recovery |
      | bounded-tool-results |
      | bundled-zip-safety |
      | claude-api-key-provider |
      | clean-readiness-parity |
      | compact-ack-guidance |
      | compact-shaping-context |
      | documentation-lookup-evidence |
      | faster-shaping |
      | legacy-usage-coverage |
      | opencode-go-subscription |
      | prompt-cache-reuse-and-usage |
      | reuse-ready-evidence-v2 |
      | shape-context-index |
      | shape-working-context |
      | shape-working-summary |
      | shaping-evidence-quality |
      | shaping-technical-discovery |
      | supergrok-subscription-20261022 |
    Then every selected Go migration scenario passed exactly once

  @go-build
  Scenario: Native installed Build verification independent Review and signed commit
    When I run these Go migration installed specifications:
      | spec/features/04-building.feature |
      | spec/features/05-verifying.feature |
      | spec/features/06-reviewing.feature |
      | spec/features/07-committing.feature |
    Then every selected Go migration scenario passed exactly once

  @go-build
  Scenario: Current continuation recovery staged progress and custody contracts survive
    Given these accumulated scenarios are superseded by prompt caching:
      | native-image-evidence | Resume frozen Build pixels and use fresh reviewer access        | fallback |
      | native-image-evidence | Unsupported cache controls do not change image content on retry |          |
    And these accumulated scenarios are superseded by main's version-3 checkpoint rule:
      | reopen-blocked-review | Reopen a real retained signed C3 checkpoint |
    When I run these accumulated Go migration contracts:
      | build-continuity |
      | build-diagnostic-context |
      | build-unblocking-recovery |
      | clean-candidate-verification |
      | deterministic-check-gate |
      | fail-fast-verification |
      | native-image-evidence |
      | provider-wait-boundary |
      | reopen-blocked-review |
      | resume-failed-builds |
      | review-refine-working-room |
      | reviewer-style-discipline |
      | staged-intent-builds |
      | terminal-protocol-compatibility |
      | terminal-validation-evidence |
      | transient-stream-retry |
      | usable-check-protection |
    Then every selected Go migration scenario passed exactly once

  @go-build @go-final
  Scenario: A genuine C3 version-2 checkpoint is refused exactly as main 76109e1 refuses it
    When I resume a genuine C3 version-2 checkpoint with the installed candidate
    Then the Go migration C3 checkpoint observations are:
      | c3_version_line                  | true                      |
      | c3_codesign_verified             | true                      |
      | candidate_is_not_c3              | true                      |
      | blocked_run_reproduced           | true                      |
      | checkpoint_version               | 2                         |
      | resume_exit                      | 1                         |
      | resume_output_exact              | true                      |
      | provider_requests_during_resume  | 0                         |
      | new_build_run_directories        | 0                         |
      | state_unchanged_after_resume     | true                      |
      | inspect_exit                     | 1                         |
      | inspect_error                    | "intent/run_not_found"    |
      | state_unchanged_after_inspect    | true                      |

  @go-build @go-final
  Scenario Outline: Prompt caching reuses every conversation's prefix on <provider>
    When I build and independently review one approved Intent with the installed candidate on the caching <provider> fake, interrupting the builder once and resuming it
    Then the Go migration cache observations are:
      | conversations                 | 2                |
      | append_only_violations        | []               |
      | frozen_front_violations       | []               |
      | routing_keys_per_conversation | [1,1]            |
      | distinct_routing_keys         | 2                |
      | routing                       | <routing>        |
      | anthropic_breakpoints         | <breakpoints>    |
      | cache_refusal_retries         | 0                |
      | min_cached_share_after_first  | 0.9              |
      | recorded_cached_matches_fake  | true             |
      | usage_reports_cached_share    | true             |
    Examples:
      | provider    | routing                                         | breakpoints                                   |
      | chatgpt     | "body prompt_cache_key only" | "none"                                        |
      | supergrok   | "body prompt_cache_key"                         | "none"                                        |
      | opencode-go | "header x-opencode-session"                     | "none"                                        |
      | anthropic   | "none"                                          | "last tool, last system block, newest message" |
      | openai-compatible | "none"                                    | "none"                                        |

  @go-shape @go-final
  Scenario: Any model and effort reach every provider unchanged and a refusal is clear
    When I run the open model selection journeys with the installed candidate
    Then the Go migration open model observations are:
      | chatgpt: exit                                           | 4 |
      | chatgpt: requests                                       | 1 |
      | chatgpt: path                                           | "/v1/responses" |
      | chatgpt: model sent                                     | "model-nobody-listed-1" |
      | chatgpt: effort sent                                    | "effort-nobody-listed" |
      | chatgpt: error line                                     | "provider/model_unavailable: model-nobody-listed-1 is not available to this ChatGPT account" |
      | chatgpt: hint line                                      | "model model-nobody-listed-1 with effort effort-nobody-listed was sent to ChatGPT unchanged and not retried; if ChatGPT does not offer them, set another model or effort for this role in .kogen/project.yaml" |
      | supergrok: exit                                         | 4 |
      | supergrok: requests                                     | 1 |
      | supergrok: path                                         | "/v1/responses" |
      | supergrok: model sent                                   | "model-nobody-listed-1" |
      | supergrok: effort sent                                  | "effort-nobody-listed" |
      | supergrok: error line                                   | "provider/model_unavailable: model-nobody-listed-1 is not available to this SuperGrok account" |
      | supergrok: hint line                                    | "model model-nobody-listed-1 with effort effort-nobody-listed was sent to SuperGrok unchanged and not retried; if SuperGrok does not offer them, set another model or effort for this role in .kogen/project.yaml" |
      | opencode-go: exit                                       | 4 |
      | opencode-go: requests                                   | 1 |
      | opencode-go: path                                       | "/inference/go/openai/v1/chat/completions" |
      | opencode-go: model sent                                 | "model-nobody-listed-1" |
      | opencode-go: effort sent                                | "effort-nobody-listed" |
      | opencode-go: error line                                 | "provider/model_unavailable: OpenCode Go refused HTTP 404; no route or model fallback" |
      | opencode-go: hint line                                  | "model model-nobody-listed-1 with effort effort-nobody-listed was sent to OpenCode Go unchanged and not retried; if OpenCode Go does not offer them, set another model or effort for this role in .kogen/project.yaml" |
      | anthropic: exit                                         | 4 |
      | anthropic: requests                                     | 1 |
      | anthropic: path                                         | "/v1/messages" |
      | anthropic: model sent                                   | "model-nobody-listed-1" |
      | anthropic: effort sent                                  | "effort-nobody-listed" |
      | anthropic: error line                                   | "provider/model_unavailable: Anthropic refused HTTP 404; no route or model fallback" |
      | anthropic: hint line                                    | "model model-nobody-listed-1 with effort effort-nobody-listed was sent to Anthropic unchanged and not retried; if Anthropic does not offer them, set another model or effort for this role in .kogen/project.yaml" |
      | openai-compatible: exit                                 | 4 |
      | openai-compatible: requests                             | 1 |
      | openai-compatible: path                                 | "/v1/chat/completions" |
      | openai-compatible: model sent                           | "model-nobody-listed-1" |
      | openai-compatible: effort sent                          | "effort-nobody-listed" |
      | openai-compatible: error line                           | "provider/model_unavailable: OpenAI-compatible refused HTTP 404; no route or model fallback" |
      | openai-compatible: hint line                            | "model model-nobody-listed-1 with effort effort-nobody-listed was sent to OpenAI-compatible unchanged and not retried; if OpenAI-compatible does not offer them, set another model or effort for this role in .kogen/project.yaml" |
      | opencode-go with effort default: requests               | 1 |
      | opencode-go with effort default: model sent             | "model-nobody-listed-1" |
      | opencode-go with effort default: reasoning_effort       | "absent" |
      | openai-compatible with effort default: requests         | 1 |
      | openai-compatible with effort default: model sent       | "model-nobody-listed-1" |
      | openai-compatible with effort default: reasoning_effort | "absent" |
      | openai-compatible no error code (404): exit             | 4 |
      | openai-compatible no error code (404): requests         | 1 |
      | openai-compatible no error code (404): error line       | "provider/refused: OpenAI-compatible refused HTTP 404; no route or model fallback" |
      | openai-compatible no error code (404): hint line        | "model model-nobody-listed-1 with effort effort-nobody-listed was sent to OpenAI-compatible unchanged and not retried; if OpenAI-compatible does not offer them, set another model or effort for this role in .kogen/project.yaml" |
      | openai-compatible invalid effort (400): exit            | 4 |
      | openai-compatible invalid effort (400): requests        | 1 |
      | openai-compatible invalid effort (400): error line      | "provider/refused: OpenAI-compatible refused HTTP 400; no route or model fallback" |
      | openai-compatible invalid effort (400): hint line       | "model model-nobody-listed-1 with effort effort-nobody-listed was sent to OpenAI-compatible unchanged and not retried; if OpenAI-compatible does not offer them, set another model or effort for this role in .kogen/project.yaml" |
      | keyless openai-compatible: provider list                | ["chatgpt: not signed in", "supergrok: not signed in", "opencode-go: not signed in", "anthropic: not signed in"] |
      | keyless openai-compatible: Authorization header         | "absent" |
      | keyless openai-compatible: exit                         | 4 |
      | openai-compatible login: exit                           | 0 |
      | openai-compatible login: output                         | ["openai-compatible: key saved (not verified)"] |
      | openai-compatible login: credential file mode           | 384 |
      | saved key: provider list                                | ["chatgpt: not signed in", "supergrok: not signed in", "opencode-go: not signed in", "anthropic: not signed in", "openai-compatible: key saved (not verified)"] |
      | saved key: Authorization header                         | "Bearer SYNTHETIC_LOCAL_HOST_KEY" |
      | saved key: exit                                         | 4 |
      | saved key: requests                                     | 1 |
      | base_url on chatgpt: exit                               | 3 |
      | base_url on chatgpt: requests                           | 0 |
      | base_url on chatgpt: output                             | ["environment/project_config_invalid: <checkout>/.kogen/project.yaml", "line 11: models.shape.base_url is only for provider openai-compatible", "line 12: models.build.base_url is only for provider openai-compatible", "line 13: models.review.base_url is only for provider openai-compatible"] |
      | base_url on supergrok: exit                             | 3 |
      | base_url on supergrok: requests                         | 0 |
      | base_url on supergrok: output                           | ["environment/project_config_invalid: <checkout>/.kogen/project.yaml", "line 11: models.shape.base_url is only for provider openai-compatible", "line 12: models.build.base_url is only for provider openai-compatible", "line 13: models.review.base_url is only for provider openai-compatible"] |
      | base_url on opencode-go: exit                           | 3 |
      | base_url on opencode-go: requests                       | 0 |
      | base_url on opencode-go: output                         | ["environment/project_config_invalid: <checkout>/.kogen/project.yaml", "line 11: models.shape.base_url is only for provider openai-compatible", "line 12: models.build.base_url is only for provider openai-compatible", "line 13: models.review.base_url is only for provider openai-compatible"] |
      | base_url on anthropic: exit                             | 3 |
      | base_url on anthropic: requests                         | 0 |
      | base_url on anthropic: output                           | ["environment/project_config_invalid: <checkout>/.kogen/project.yaml", "line 11: models.shape.base_url is only for provider openai-compatible", "line 12: models.build.base_url is only for provider openai-compatible", "line 13: models.review.base_url is only for provider openai-compatible"] |
      | openai-compatible without base_url: exit                | 3 |
      | openai-compatible without base_url: requests            | 0 |
      | openai-compatible without base_url: output              | ["environment/project_config_invalid: <checkout>/.kogen/project.yaml", "line 11: models.shape: openai-compatible needs base_url, for example http://localhost:11434/v1", "line 12: models.build: openai-compatible needs base_url, for example http://localhost:11434/v1", "line 13: models.review: openai-compatible needs base_url, for example http://localhost:11434/v1"] |
      | openai-compatible with base_url ftp://host/v1: exit     | 3 |
      | openai-compatible with base_url ftp://host/v1: requests | 0 |
      | openai-compatible with base_url ftp://host/v1: output   | ["environment/project_config_invalid: <checkout>/.kogen/project.yaml", "line 11: models.shape.base_url must be an http:// or https:// URL", "line 12: models.build.base_url must be an http:// or https:// URL", "line 13: models.review.base_url must be an http:// or https:// URL"] |

  @go-final
  Scenario: No active Elixir Kogen core or bridge remains in source or candidate archive
    When I inspect Go migration source and archive for removed paths:
      | lib |
      | config |
      | rel |
      | mix.exs |
      | mix.lock |
    Then the Go migration no longer ships an Elixir core

  @go-final
  Scenario: Native installed process CLI installation and deterministic release-helper journeys
    When I run these Go migration installed specifications:
      | spec/features/09-cli-and-process.feature |
      | spec/features/10-install-and-uninstall.feature |
      | spec/features/11-release-acceptance.feature |
    Then every selected Go migration scenario passed exactly once

  @go-final
  Scenario: Every accumulated maintained Intent contract passes on the final candidate
    Given these accumulated scenarios are superseded by prompt caching:
      | opencode-go-subscription     | ChatGPT keeps the exact recognized rejection compatibility without losing replay |          |
      | prompt-cache-reuse-and-usage | Complete Shape authority and valid replay reach consecutive provider requests    |          |
      | prompt-cache-reuse-and-usage | Build and saved review preserve reuse without sharing authority                  |          |
      | prompt-cache-reuse-and-usage | Cache capability handling uses only safe necessary calls                         |          |
      | native-image-evidence        | Resume frozen Build pixels and use fresh reviewer access                         | fallback |
      | native-image-evidence        | Unsupported cache controls do not change image content on retry                  |          |
    And these accumulated scenarios are superseded by open model selection:
      | opencode-go-subscription | Unqualified Go models and efforts are rejected before inference                   |                                                      |
      | claude-api-key-provider  | Select documented Claude models and the initial Kogen effort subset independently | anthropic / claude-invented / high / false / refused |
      | claude-api-key-provider  | Select documented Claude models and the initial Kogen effort subset independently | anthropic / claude-opus-5-5 / xhigh / true / refused |
    And these accumulated scenarios are superseded by main's version-3 checkpoint rule:
      | reopen-blocked-review | Reopen a real retained signed C3 checkpoint |
    When I run these accumulated Go migration contracts:
      | all-provider-cache-reuse |
      | approval-card-recovery |
      | bounded-tool-results |
      | build-continuity |
      | build-diagnostic-context |
      | build-unblocking-recovery |
      | bundled-zip-safety |
      | checkout-cli-dx |
      | claude-api-key-provider |
      | clean-candidate-verification |
      | clean-readiness-parity |
      | compact-ack-guidance |
      | compact-shaping-context |
      | deterministic-check-gate |
      | documentation-lookup-evidence |
      | fail-fast-verification |
      | faster-shaping |
      | legacy-usage-coverage |
      | native-image-evidence |
      | opencode-go-subscription |
      | prompt-cache-reuse-and-usage |
      | provider-wait-boundary |
      | reopen-blocked-review |
      | resume-failed-builds |
      | reuse-ready-evidence-v2 |
      | review-refine-working-room |
      | reviewer-style-discipline |
      | shape-context-index |
      | shape-working-context |
      | shape-working-summary |
      | shaping-evidence-quality |
      | shaping-technical-discovery |
      | spec-vocabulary-integrity |
      | staged-intent-builds |
      | supergrok-subscription-20261022 |
      | terminal-protocol-compatibility |
      | terminal-validation-evidence |
      | transient-stream-retry |
      | usable-check-protection |
    Then every selected Go migration scenario passed exactly once

  @go-final
  Scenario: Complete deterministic suite and uncached native race tests pass
    When I run the Go migration deterministic delivery commands:
      | . | sh test/suite.sh |
    Then the Go migration deterministic delivery commands all passed
