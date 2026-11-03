Feature: Kogen's acceptance observes only the built kogen binary
  Kogen's Intent acceptance observes the built kogen binary from outside: CLI output, files, Git state and the
  fake provider's HTTP exchanges. The Go observation drivers that features/steps mounted with go test -overlay into
  cli/build, cli/shape, cli/executor and cli/verify, which left kogen at the 2 Nov extraction, are removed with every
  step and scenario that depended on them, and cli/testdata/legacy, a copy of kogen-build's build/testdata/legacy,
  is removed while the Go tests that run the kogen binary stay.

  Scenario: The overlay drivers and the step files that only served them are gone
    Then the checkout has none of these paths:
      | path |
      | features/steps/k11_review_unread_driver.go |
      | features/steps/k12_adapter_driver.go |
      | features/steps/k12_shape_driver.go |
      | features/steps/k14_limit_raises_driver.go |
      | features/steps/k16_cc_builder_blocker_driver.go |
      | features/steps/k19_no_progress_driver.go |
      | features/steps/k20_shape_step_selfcheck_driver.go |
      | features/steps/k25_request_audit_driver.go |
      | features/steps/k25b_coverage_driver.go |
      | features/steps/k25c_gate_driver.go |
      | features/steps/k26_decision_check_driver.go |
      | features/steps/k26b_source_tag_driver.go |
      | features/steps/k26c_fallback_driver.go |
      | features/steps/k26d_whitespace_driver.go |
      | features/steps/k26e_fallback_driver.go |
      | features/steps/k5b_build_check_driver.go |
      | features/steps/k9_build_record_driver.go |
      | features/steps/k9_shape_record_driver.go |
      | features/steps/k_accept_server_leak_driver.go |
      | features/steps/k_build_early_stop_driver.go |
      | features/steps/k_env_failure_park_driver.go |
      | features/steps/k_hook_prevalidation_driver.go |
      | features/steps/k_intent_line_period_driver.go |
      | features/steps/k_load_flakes_driver.go |
      | features/steps/k_review_invalid_resume_driver.go |
      | features/steps/k_review_resume_driver.go |
      | features/steps/k_review_source_bound_driver.go |
      | features/steps/k_shape_hooks_driver.go |
      | features/steps/krevod_driver.go |
      | features/steps/review_efficiency_driver.go |
      | features/steps/k11_review_unread_steps.js |
      | features/steps/k12_cc_shape_readonly_steps.js |
      | features/steps/k14_limit_raises_steps.js |
      | features/steps/k16_cc_builder_blocker_steps.js |
      | features/steps/k19_no_progress_steps.js |
      | features/steps/k20_shape_step_selfcheck_steps.js |
      | features/steps/k25_request_audit_steps.js |
      | features/steps/k25b_coverage_steps.js |
      | features/steps/k25c_gate_steps.js |
      | features/steps/k26_decision_check_steps.js |
      | features/steps/k26b_source_tag_steps.js |
      | features/steps/k26c_fallback_steps.js |
      | features/steps/k26d_whitespace_steps.js |
      | features/steps/k26e_fallback_steps.js |
      | features/steps/k9_run_record_steps.js |
      | features/steps/k_build_early_stop_steps.js |
      | features/steps/k_env_failure_park_steps.js |
      | features/steps/k_go_test_critical_path_steps.js |
      | features/steps/k_hook_prevalidation_steps.js |
      | features/steps/k_load_flakes_steps.js |
      | features/steps/k_review_invalid_resume_steps.js |
      | features/steps/k_review_resume_steps.js |
      | features/steps/k_review_source_bound_steps.js |
      | features/steps/k_shape_hooks_steps.js |
      | features/steps/review_efficiency_steps.js |
    And the Go files under "features/steps" are exactly these, each declaring package main:
      | file |
      | k5b_probe_driver.go |
      | k_fake_runner_step_evidence_driver.go |
      | k_probe_mix_home_driver.go |
      | model_family_profiles_driver.go |
    And no file under "features/steps" contains any of these texts:
      | text |
      | -overlay |
      | k11_review_unread_driver |
      | k12_adapter_driver |
      | k12_shape_driver |
      | k14_limit_raises_driver |
      | k16_cc_builder_blocker_driver |
      | k19_no_progress_driver |
      | k20_shape_step_selfcheck_driver |
      | k25_request_audit_driver |
      | k25b_coverage_driver |
      | k25c_gate_driver |
      | k26_decision_check_driver |
      | k26b_source_tag_driver |
      | k26c_fallback_driver |
      | k26d_whitespace_driver |
      | k26e_fallback_driver |
      | k5b_build_check_driver |
      | k9_build_record_driver |
      | k9_shape_record_driver |
      | k_accept_server_leak_driver |
      | k_build_early_stop_driver |
      | k_env_failure_park_driver |
      | k_hook_prevalidation_driver |
      | k_intent_line_period_driver |
      | k_load_flakes_driver |
      | k_review_invalid_resume_driver |
      | k_review_resume_driver |
      | k_review_source_bound_driver |
      | k_shape_hooks_driver |
      | krevod_driver |
      | review_efficiency_driver |
    And the checkout has each of these paths:
      | path |
      | features/steps/go_driver_support.js |
      | features/steps/k_accept_server_leak_steps.js |
      | features/steps/k_intent_line_period_steps.js |
      | features/steps/krevod_steps.js |
      | features/steps/k5b_loop_repin_ksafe_steps.js |
      | features/steps/k5b_probe_driver.go |

  Scenario: Intents whose every scenario observed internals through a driver are removed
    Then the checkout has none of these paths:
      | path |
      | .kogen/intents/k-build-early-stop |
      | .kogen/intents/k-env-failure-park |
      | .kogen/intents/k-go-test-critical-path |
      | .kogen/intents/k-hook-prevalidation |
      | .kogen/intents/k-load-flakes |
      | .kogen/intents/k-review-invalid-resume |
      | .kogen/intents/k-review-resume |
      | .kogen/intents/k-review-source-bound |
      | .kogen/intents/k-shape-hooks |
      | .kogen/intents/k11-review-unread-parts |
      | .kogen/intents/k12-cc-shape-readonly |
      | .kogen/intents/k14-review-limit-raises |
      | .kogen/intents/k16-cc-builder-blocker |
      | .kogen/intents/k19-no-progress-stop |
      | .kogen/intents/k20-shape-step-selfcheck |
      | .kogen/intents/k25-request-audit |
      | .kogen/intents/k25b-undefined-coverage |
      | .kogen/intents/k25c-gate-no-refusal |
      | .kogen/intents/k26-decision-check |
      | .kogen/intents/k26b-source-tag |
      | .kogen/intents/k26c-decision-fallback |
      | .kogen/intents/k26d-whitespace-match |
      | .kogen/intents/k26e-fallback-any-statement |
      | .kogen/intents/k9-run-record-fields |
      | .kogen/intents/review-efficiency |

  Scenario: Intents with outside checks keep exactly those scenarios, byte for byte, and no longer list a removed driver
    Then the scenarios of ".kogen/intents/k-accept-server-leak/acceptance.feature" are exactly these, with their SHA-256 block digests:
      | scenario | sha256 |
      | Approval through the bundled Cucumber leaves no background server of its <scenario> fixture scenario | 8a7e0bd456bc1e81de2c167617af53b9fb36b663a79203e34c01be8befb06e08 |
    And the Acceptance list of ".kogen/intents/k-accept-server-leak/intent.md" is exactly:
      """
      .kogen/intents/k-accept-server-leak/acceptance.feature
      features/steps/k_accept_server_leak_steps.js
      """
    And the scenarios of ".kogen/intents/k-intent-line-period/acceptance.feature" are exactly these, with their SHA-256 block digests:
      | scenario | sha256 |
      | The specification states the accepted trailing period | 633f51f5dac547fa6635443526cf97bf454de39abfac1c6a143877391a8ab11a |
    And the Acceptance list of ".kogen/intents/k-intent-line-period/intent.md" is exactly:
      """
      .kogen/intents/k-intent-line-period/acceptance.feature
      features/steps/k_intent_line_period_steps.js
      """
    And the scenarios of ".kogen/intents/k-revod/acceptance.feature" are exactly these, with their SHA-256 block digests:
      | scenario | sha256 |
      | The key is documented as experimental and off by default | d035bc2eff5b490cd0e8845a60e8b8e2e078f9bf7d1ffe28e43a3f6ce6eb05bd |
    And the Acceptance list of ".kogen/intents/k-revod/intent.md" is exactly:
      """
      .kogen/intents/k-revod/acceptance.feature
      features/steps/krevod_steps.js
      """
    And the scenarios of ".kogen/intents/k5b-loop-repin-ksafe/acceptance.feature" are exactly these, with their SHA-256 block digests:
      | scenario | sha256 |
      | The vendored copy is exactly the clean source at 2ea31bf5 | 8c0dffbffc42c39c53b1deec45a4529a470b3b2c69a61fb2d331c4bbeff70382 |
      | A probe that would stop a sibling process is refused and the round continues | 875cf51b51e9123239386e91e7ce6fa9e8b21a44ba23501fd0d4c16c58d9ac4a |
      | A probe that starts a background sleep leaves no group member behind | f9610cf3ffe7ceb1fb7c24501fd9a8be0b3e485cf61789cca3a224e904c3baa3 |
      | A probe with a short deadline still reports a timeout | 0a1c6a37a234599513bbb405a867cfcd6ca589ad35f92162e30ef682038fafce |
      | The specification and executor contract state the enforcement and its limits | ea3e58d456352efe22cfd06bc94cc61ba854a1385f8e7a85035e8c3ea7f030cb |
      | A new evidence note records the re-pin and older notes stay intact | 233fa16459f62c43f0569ead21f2a92fa65a0442099a7a8d1f280656a07098fc |
    And the Acceptance list of ".kogen/intents/k5b-loop-repin-ksafe/intent.md" is exactly:
      """
      .kogen/intents/k5b-loop-repin-ksafe/acceptance.feature
      features/steps/k5b_loop_repin_ksafe_steps.js
      features/steps/k5b_probe_driver.go
      """

  Scenario: The kept scenarios still pass with the step library that remains
    Then the checkout has none of these paths:
      | path |
      | features/steps/k_accept_server_leak_driver.go |
      | features/steps/k_intent_line_period_driver.go |
      | features/steps/krevod_driver.go |
      | features/steps/k5b_build_check_driver.go |
    When the bundled Cucumber runs these kept scenarios with the step library:
      | feature | scenario | runs |
      | .kogen/intents/k-accept-server-leak/acceptance.feature | Approval through the bundled Cucumber leaves no background server of its passing fixture scenario | 1 |
      | .kogen/intents/k-accept-server-leak/acceptance.feature | Approval through the bundled Cucumber leaves no background server of its failing fixture scenario | 1 |
      | .kogen/intents/k-intent-line-period/acceptance.feature | The specification states the accepted trailing period | 1 |
      | .kogen/intents/k-revod/acceptance.feature | The key is documented as experimental and off by default | 1 |
      | .kogen/intents/k5b-loop-repin-ksafe/acceptance.feature | A probe that would stop a sibling process is refused and the round continues | 3 |
      | .kogen/intents/k5b-loop-repin-ksafe/acceptance.feature | A probe that starts a background sleep leaves no group member behind | 1 |
      | .kogen/intents/k5b-loop-repin-ksafe/acceptance.feature | A probe with a short deadline still reports a timeout | 1 |
      | .kogen/intents/k5b-loop-repin-ksafe/acceptance.feature | The specification and executor contract state the enforcement and its limits | 1 |
      | .kogen/intents/k5b-loop-repin-ksafe/acceptance.feature | A new evidence note records the re-pin and older notes stay intact | 1 |
    Then each of those scenarios passed its number of runs and nothing else ran

  Scenario: Every other Intent's acceptance still binds to the step library
    When the bundled Cucumber dry-runs every Intent acceptance feature except this Intent's own
    Then the dry run reports 871 scenarios, none with an ambiguous step, and undefined steps only in:
      | feature | scenarios |
      | .kogen/intents/k-examples-outline/acceptance.feature | 6 |
      | .kogen/intents/k-shape-acceptance-contradicts/acceptance.feature | 8 |

  Scenario: The copy of kogen-build's legacy fixture is gone and the Go tests that run the kogen binary stay
    When Go runs the test "TestUsageLimitResumeInstalledRound2" in package "." of cli
    Then that Go test passed exactly once
    And the checkout has none of these paths:
      | path |
      | cli/testdata/legacy |
    When Go lists the tests of package "." of cli matching "^TestUsageLimit"
    Then the listed Go tests are exactly:
      | test |
      | TestUsageLimitResumeInstalledRound2 |
      | TestUsageLimitResumeInstalledRound3 |
      | TestUsageLimitPackagingIsolationRound2 |
      | TestUsageLimitPackagingIsolationRound3 |
    When Go lists the tests of package "./buildprogram" of cli matching "^Test"
    Then the listed Go tests are exactly:
      | test |
      | TestBaselinePerBaseInstalled |
      | TestBaselinePackagingIsolation |
      | TestKReviewVerdictStrandPinnedResume |
      | TestKReviewRetryReviewOnlyResume |
      | TestKReviewRetryChangedCheckout |
      | TestSatisfiedRebuildAlreadyPresent |
      | TestSatisfiedRebuildPreservesStagedIntent |
