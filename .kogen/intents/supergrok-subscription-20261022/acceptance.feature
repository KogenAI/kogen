Feature: SuperGrok subscription provider
  Background:
    Given the SuperGrok qualification inputs:
      """
      {"budget":524288,"reserve":131072,"opaque":"synthetic opaque+/==\nΔ🙂","borrowed":"BORROWED_HARNESS_TOKEN_MUST_NOT_BE_READ"}
      """

  Scenario: Kogen's own device login stores one private exact credential
    When I exercise the SuperGrok provider "login"
    Then the SuperGrok observations include:
      """
      {"exit":0,"stdout_exact":true,"device_request_exact":true,"identity_honest":true,"polls_exact":true,"paced_by_server":true,"slow_down_respected":true,"credential_exact":true,"private":true,"lock_released":true,"list_both":true,"list_offline":true,"borrowed_unused":true,"secrets_safe":true}
      """

  Scenario: Refused, expired and cancelled device logins keep nothing
    When I exercise the SuperGrok provider "login-refusals"
    Then the SuperGrok observations include:
      """
      {"refusals":{"missing_scope":true,"no_tokens":true,"denied":true,"expired_token":true,"deadline":true,"not_https":true,"incomplete":true,"rejected":true,"cancel":true,"unknown_grok":true,"unknown_xai":true}}
      """

  Scenario: Shape, Refine, Build and a fresh Review run on SuperGrok with exact replay and refresh
    When I exercise the SuperGrok provider "workflow"
    Then the SuperGrok observations include:
      """
      {"shape_exit":0,"refine_exit":0,"approve_exit":0,"build_exit":0,"one_commit":true,"wire_exact":true,"no_chatgpt":true,"replay_exact":true,"typed_image":true,"bounded":true,"review_independent":true,"refresh_kept":true,"retry_once":true,"credential_private":true,"usage_provider":true,"usage_null_absent":true,"secrets_safe":true}
      """

  Scenario: Rejections, limits and unsupported choices never fall back
    When I exercise the SuperGrok provider "limits"
    Then the SuperGrok observations include:
      """
      {"limits":{"s401_twice":true,"s402":true,"s403":true,"s429":true,"model":true,"budget":true,"bad_provider":true,"bad_model":true,"bad_effort":true,"not_signed_in":true,"borrowed_file":true},"no_fallback":true,"no_api_key":true,"secrets_safe":true}
      """

  Scenario: Omitting the provider keeps ChatGPT behavior and saved checkpoints exact
    When I exercise the SuperGrok provider "legacy"
    Then the SuperGrok observations include:
      """
      {"maps_exact":true,"workers_exact":true,"explicit_chatgpt":true,"body_bytes_same":true,"chatgpt_headers_same":true,"chatgpt_token_only":true,"list_both":true,"checkpoint_legacy":true,"provider_edit_refused":true,"changed_since_approval":true,"resume_lands":true,"usage_chatgpt":true,"older_usage_null":true}
      """
