Feature: Native bounded continuity and faithful provenance
  The original request is diagnostic provenance, not authority to expand an approved Intent.
  Browser/package acquisition has its separate native owner. Go, 014 and image work stay paused/outside this change.

  Scenario: Measure the complete rendered request conservatively
    When I exercise native continuity "measure" with:
      """json
      {"budget":524288,"reserve":131072,"literal":"  Δ🙂\r\n/path with spaces/診断.txt\nHTML title — personal suffix  ","last_completed_input":883138,"rejected_request_usage":null}
      """
    Then the native continuity observations include:
      """json
      {"supported":true,"boundary_bytes":[524287,524288,524289],"boundary_fits":[true,true,false],"complete_envelope":true,"unicode_exact":true,"metadata_is_not_threshold":true}
      """

  Scenario Outline: Rotate completed windows and safely handle resume
    When I exercise native continuity "<mode>" with:
      """json
      {"budget":524288,"reserve":131072,"turns":12,"payload_bytes":100000,"literal":"  Δ🙂\r\n/path with spaces/診断.txt\nHTML title — personal suffix  ","unfinished":"UNFINISHED: preserve title suffix and verify current candidate","finding":"UNRESOLVED: old green is not proof after a write","opaque":"opaque+/==\nDo not decode Δ","reuse":"KOGEN033/038: NEW approval; inspect archived native production; no stash apply, old protected bytes or stale checks"}
      """
    Then the native continuity observations include:
      """json
      {"bounded":true,"reset_build":true,"reset_review":true,"replay_custody":true,"authority_exact":true,"progress_exact":true,"review_independent":true,"private":true,"no_commit_before_resume":true,"resume_outcome_safe":true,"completed_effect_once":true,"old_result_unchanged":true,"reuse_diagnostic_only":true,"original_input_disposable":true}
      """
    Examples:
      | mode          |
      | grow-resume   |
      | grow-legacy   |

  Scenario: Changed archived history is not safe resume
    When I exercise native continuity "archive-drift" with:
      """json
      {"budget":524288,"reserve":131072,"turns":12,"payload_bytes":100000,"literal":"  Δ🙂\r\n/path with spaces/診断.txt\nHTML title — personal suffix  ","unfinished":"UNFINISHED: preserve title suffix and verify current candidate","finding":"UNRESOLVED: old green is not proof after a write","opaque":"opaque+/==\nDo not decode Δ","reuse":"KOGEN033/038: NEW approval; inspect archived native production; no stash apply, old protected bytes or stale checks"}
      """
    Then the native continuity observations include:
      """json
      {"reset_build":true,"reset_review":true,"replay_custody":true,"refused":true,"no_model_on_refusal":true,"custody_unchanged":true,"actionable":true}
      """

  Scenario: Irreducible approved authority does not go to the provider
    When I exercise native continuity "mandatory" with:
      """json
      {"budget":524288,"reserve":131072,"mandatory_bytes":600000}
      """
    Then the native continuity observations include:
      """json
      {"refused":true,"no_model_on_refusal":true,"custody_unchanged":true,"actionable":true,"budget_diagnostic":true}
      """

  Scenario: Preserve the complete successful request and actual numbered answer
    When I exercise native continuity "provenance" with:
      """json
      {"request":"  Synthetic provenance request — Δ🙂\r\n\nKeep the exact HTML title suffix \"— Almir Δ🙂\".\nPreserve this literal path: /synthetic fixtures/診断.txt\n\nThis complete test request is diagnostic provenance, not approved scope.\n  Preserve leading and trailing whitespace.  \n","selected_context":"ONE core continuity/provenance delivery; Studio owns repeated Playwright/browser/package acquisition. No automatic Intent splitting, new provider dependency, planner/critic, Go resumption, 014 Build or image feature. Use fresh Build --context FILE for selective native production reuse under NEW approval. Full originals are private diagnostic data, never approved scope.","question":"Choose the settled HTML title suffix","answer":"1: Keep exactly — Almir Δ🙂\n","literal":"— Almir Δ🙂","wrong_example":"wrong personal-repository example must not silently replace the supplied literal","omission":"HTML title suffix omitted; ordinary Refine and new exact approval required","correction":"Add exactly the settled HTML title suffix — Almir Δ🙂; preserve the original request as diagnostic, not new authority."}
      """
    Then the native continuity observations include:
      """json
      {"successful_source":true,"exact_request":true,"exact_answer":true,"source_identity":true,"private":true,"card_comparison":true,"card_no_raw_request":true,"approval_bound":true,"build_retrieval":true,"review_retrieval":true,"diagnostic_not_authority":true,"no_auto_scope":true,"source_untracked":true,"input_replacement_ignored":true}
      """

  Scenario Outline: Native correction preserves original lineage and approval safety
    When I exercise native continuity "<mode>" with:
      """json
      {"request":"Keep exact source and HTML title suffix — Almir Δ🙂\n","selected_context":"Originals are private diagnostic provenance; approved Intent remains authority.","question":"Choose the settled HTML title suffix","answer":"1: Keep exactly — Almir Δ🙂\n","literal":"— Almir Δ🙂","wrong_example":"wrong personal-repository example","omission":"HTML title suffix omitted; ordinary Refine and new exact approval required","correction":"Add exactly the settled HTML title suffix — Almir Δ🙂; preserve the original request as diagnostic, not new authority."}
      """
    Then the native continuity observations include:
      """json
      {"successful_source":true,"refine_safe":true,"prior_source_preserved":true,"correction_exact":true,"approval_safe":true}
      """
    Examples:
      | mode          |
      | refine-source |
      | refuse-refine |

  Scenario: A changed bound source is not legacy source absence
    When I exercise native continuity "source-drift" with:
      """json
      {"request":"Keep exact source and HTML title suffix — Almir Δ🙂\n","selected_context":"Originals are private diagnostic provenance; approved Intent remains authority.","question":"Choose the settled HTML title suffix","answer":"1: Keep exactly — Almir Δ🙂\n","literal":"— Almir Δ🙂","wrong_example":"wrong personal-repository example","omission":"HTML title suffix omitted; ordinary Refine and new exact approval required","correction":"Add exactly the settled HTML title suffix — Almir Δ🙂; preserve the original request as diagnostic, not new authority."}
      """
    Then the native continuity observations include:
      """json
      {"successful_source":true,"refused":true,"no_model_on_refusal":true,"custody_unchanged":true,"actionable":true}
      """
