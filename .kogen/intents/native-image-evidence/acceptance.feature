Feature: Native bounded image evidence
  Background:
    Given the native image qualification inputs:
      """
      {"budget":524288,"reserve":131072,"max_bytes":131072,"max_dimension":2048,"turns":18,"payload_bytes":30000,"opaque":"synthetic opaque+/==\nΔ🙂","unfinished":"UNFINISHED synthetic image assessment","observation":"Synthetic visual observation: red field and three marks; not design approval."}
      """

  Scenario: Validate PNG data and preserve typed pixels beyond text caps
    When I exercise native image evidence "validation"
    Then the native image observations include:
      """
      {"advertised":true,"accepted":["small","bytes_minus","bytes_equal","dimension_minus","dimension_equal"],"rejected":["missing","folder","bad_crc","truncated","unsupported","bytes_plus","dimension_zero","dimension_plus"],"metadata_exact":true,"typed_uncut":true,"boundary_bytes":[524287,524288,524289],"boundary_fits":[true,true,false],"reserve":131072}
      """

  Scenario: Shape gets actual typed output and replays after artifact deletion
    When I exercise native image evidence "shape"
    Then the native image observations include:
      """
      {"advertised":true,"typed_replay":true,"bounded":true,"shape_completed":true,"path_deleted":true,"read_distinct_from_delivery":true,"logs_safe":true,"protection_same":true}
      """

  Scenario Outline: Resume frozen Build pixels and use fresh reviewer access
    When I exercise native image evidence "<mode>"
    Then the native image observations include:
      """
      {"advertised":true,"typed_replay":true,"bounded":true,"saved_pixels":true,"private":true,"resume_same_input":true,"review_independent":true,"review_own_pixels":true,"explicit_observation":true,"no_commit_on_failure":true,"one_commit":true,"old_result_unchanged":true,"read_distinct_from_delivery":true,"logs_safe":true,"protection_same":true}
      """
    Examples:
      | mode          |
      | resume-change |
      | resume-delete |
      | fallback      |

  Scenario: Unsupported cache controls do not change image content on retry
    When I exercise native image evidence "fallback"
    Then the native image observations include:
      """
      {"typed_replay":true,"fallback_exact":true,"read_distinct_from_delivery":true,"one_commit":true}
      """

  Scenario: Archive full images in both owners' completed working windows
    When I exercise native image evidence "windows"
    Then the native image observations include:
      """
      {"typed_replay":true,"bounded":true,"build_archive":true,"review_archive":true,"archive_pixels":true,"saved_pixels":true,"private":true,"resume_same_input":true,"review_independent":true,"review_own_pixels":true,"one_commit":true,"logs_safe":true,"protection_same":true}
      """

  Scenario: Altered image history refuses before inference or mutation
    When I exercise native image evidence "archive-drift"
    Then the native image observations include:
      """
      {"typed_replay":true,"archive_pixels":true,"refused":true,"no_inference_on_refusal":true,"custody_unchanged":true,"actionable":true,"no_commit_on_failure":true}
      """

  Scenario Outline: Refuse an irreducible three-image exchange before inference
    When I exercise native image evidence "<mode>"
    Then the native image observations include:
      """
      {"advertised":true,"budget_refusal":true,"no_oversized_request":true,"requests_after_init":1,"custody_unchanged":true,"actionable":true,"protection_same":true}
      """
    Examples:
      | mode         |
      | budget-shape |
      | budget-build |

  Scenario: An ordinary provider rejection does not claim completed pixel delivery
    When I exercise native image evidence "delivery-failure"
    Then the native image observations include:
      """
      {"typed_replay":true,"saved_pixels":true,"delivery_failed":true,"no_completed_delivery":true,"no_commit_on_failure":true,"logs_safe":true,"protection_same":true}
      """

  Scenario: Image access does not relax uncertain executed-tool recovery
    When I exercise native image evidence "uncertain"
    Then the native image observations include:
      """
      {"saved_pixels":true,"effect_once":true,"refused":true,"no_inference_on_refusal":true,"custody_unchanged":true,"actionable":true,"no_commit_on_failure":true,"logs_safe":true,"protection_same":true}
      """
