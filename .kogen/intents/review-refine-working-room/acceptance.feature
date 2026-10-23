Feature: Native Review and Refine keep bounded working room
  Background:
    Given the working-room source packet:
      """
      # Review and Refine working room — native request
      Native slug: review-refine-working-room. Product: Kogen core (this repository). Kogen Shape investigates the actual Review and Refine cases and decides the design, the specifications, the tests, and whether they need separate contracts. This request supplies human originals and observed failures only.

      ## Exact human originals (highest authority)
      ### 23 October (five consecutive messages)
      What's the solution for this? Big intents get split into multiple smaller ones, or can intents have stages? Or some third solution?

      So for this huge Go rewrite, what would that look like?

      ok so we first fix Kogen, then use that for this multi-stage rewrite?

      Yes. Plese, let's not lose all this valuable code. You can use probably worktree for Go rewrite, right?

      Just to make it clear: shaping will figure out whether an intent needs multi-stage build, right? And then how does that look like when one approved intent is passed to the build phase?

      ### human-steering-14.txt
      Almir, 22 October 2026 (exact user message):

      I won't be there to check on you tonight, so please have some kind of 30 minute interval check for how it's going. But still, the old rules apply: you shouldn't interfere if possible and if you do make sure the Kogen is fixed so you don't have to in the future.

      ## Issue record (operator-written evidence, not authority)
      ## KOGEN-048 — Studio Review and Refine exhaust their bounded working room
      **Reported** 23 October07:01UTC by the native Studio delivery operator; root captured the operational report. **Status:** open for native investigation at the core owner's safe boundary; supported Studio recovery is active. No external core patch or overlapping writer.

      **Observed Review:** decision-history Build `d9d96225` passed its first seven acceptance scenarios/149steps and configured checks, then a provider overload ended Review. Supported resume `435b367b` refused its next Review request:538658measuredbytes,499806mandatorybytes,524288ceiling. The operator reports mandatory material includes large changed maintained documents and duplicate package/source material. This is a new continuation-room observation after the delivered initial-review material repair; it does not establish that every Review or that older repair is broken. Root has not decoded checkpoints or independently audited source.

      **Observed Refine:** after preserving/parking the candidate, the first native correction stopped at542853>524288bytes, with407344bytes of initial context and no window reset reported. A bounded second native Refine is currently running. The exact failed attempts, unknown usage, unchanged guard/authority and preserved candidates remain in the linked evidence. Do not claim recovery completed or lower the limit/clip authority.

      **Required outcome:** native Kogen investigates these actual phase-specific cases and preserves exact authority/literals/history/tool pairs/opaque replay and honest irreducible refusal. Supported continuation should avoid repeated host rewriting/reshaping solely to obtain working room. Native Shape determines the solution and whether the Review and Refine cases require separate contracts. Do not silently rebuild already delivered capabilities or insert a core repair into the live migration.

      **Evidence owner:** `/Users/almirsarajcic/Areas/Kogen/studio-work/studio-product-workflows/attention.json` (07:01:41UTC report), `decision-history-user-attribution/native-resume-1/receipt.json`, `refine-1/evidence/`, `refine-2/receipt.json`, and the two preserved native candidates. The operator's implementation suggestions are advisory evidence, not approved architecture.

      ## Retained observations (facts reported by the Studio operator from read-only checkpoint inspection; not design)
      - Review resume `435b367b` of Studio Build `d9d96225`: `review: measured 538658 bytes; mandatory 499806 bytes; ceiling 524288, output reserve 131072 tokens` (exit 1 after 19.055 s). Pass 1 of `d9d96225` had all 7 checks and 7/7 acceptance green. Review then ended on a provider overload.
      - Reported composition of the Review's mandatory input: Review mandatory input = Intent/package message (116750 B) + 'Check results of the final pass' message (356559 B) containing the full 45826 B diff AND full text of every changed/added file (README.md ~61KB, docs/development.md ~49KB, docs/agent-connection.md ~32KB, knowledge_live.ex ~32KB, steps 30KB, app.css 14KB, ...). Package files (intent/acceptance/steps) appear in both messages. Candidates touching large maintained docs leave Review no working space (cannot read a file or view one 100KB PNG).
      - Refine `refine-1` of the parked Studio candidate stopped after 38.251 s: `candidate/context_budget_exceeded: Complete next request 542853 bytes exceeds 524288`, with about 407344 bytes of initial context and no working-window reset reported. A second, differently worded Refine (`refine-2`) completed in 559.8 s.
      - The Studio operator's suggestion ("Bound Review's mandatory changed-file material (e.g. diff plus on-demand read_file for modified files, no duplicate package text) so that Review keeps a usable working window under the unchanged 524288-byte ceiling. Register as a KOGEN issue; do not change the ceiling. Also give Refine the same bounded working-window recovery Shape already has (or exclude non-target README from unclipped authority).") is advisory evidence only.
      - Evidence paths (read-only; owned by the separate Studio operator): /Users/almirsarajcic/Areas/Kogen/studio-work/studio-product-workflows/decision-history-user-attribution/native-resume-1/ (including review-check-results-message.txt), /Users/almirsarajcic/Areas/Kogen/studio-work/studio-product-workflows/decision-history-user-attribution/refine-1/, /Users/almirsarajcic/Areas/Kogen/studio-work/studio-product-workflows/decision-history-user-attribution/refine-2/, /Users/almirsarajcic/Areas/Kogen/studio-work/studio-product-workflows/decision-history-user-attribution/parked-d9d96225, and /Users/almirsarajcic/Areas/Kogen/studio-work/studio-product-workflows/attention.json.
      - Already delivered in this repository: Build/Review completed-boundary working windows (`71f7b4f3`), bounded initial review material (`7e15bf2e`), Shape working windows (`44c2e06d`) and constant-size Shape navigation (`65640c64`). Do not re-propose them; investigate why these cases still lack working room.

      ## Boundaries
      - Keep the 524288-byte inclusive ceiling, the 131072-token reserve and full rendered measurement. Keep exact authority, required literals, history, tool pairs, opaque reasoning replay, reviewer independence, final changed-tree verification, and honest irreducible refusal. No clipping, raised limit, old guardless runtime or summarizer substitution for authority.
      - Deterministic tests use local fixtures only; do not read or modify the Studio operator's files at test time.
      - Out of scope: staged Intents, transient retry (KOGEN-047), the Go migration, Studio product source, release, deployment.
      """
    And the working-room local fixture parameters:
      """
      {"budget":524288,"reserve":131072,"literal":"  Δ🙂\r\n/path with spaces/診断.txt\n  ","opaque":"opaque+/==\nDo not decode Δ","turns":24,"read_bytes":22000,"read_batch":3,"refine_readme_bytes":320000,"review_readme_bytes":61000,"review_docs_bytes":49000,"review_added_bytes":32000}
      """

  Scenario: Resume a fitted inline Review with room for investigation and final repair
    When I exercise native working room "review-resume"
    Then the native working-room observations include:
      """
      {"initial_inline_fit":true,"resumed_saved_review":true,"success":true,"source_relocated":true,"all_source_delivered":true,"authority_exact":true,"bounded":true,"independent":true,"replay_custody":true,"old_result_unchanged":true,"one_commit":true,"final_repair_verified":true}
      """

  Scenario: Review custody damage is not permission to restart or commit
    When I exercise native working room "review-damage"
    Then the native working-room observations include:
      """
      {"initial_inline_fit":true,"source_relocated":true,"custody_refused":true,"no_inference_after_damage":true,"no_commit":true,"approval_unchanged":true}
      """

  Scenario: Refine keeps proposals and exact red acknowledgment through repeated resets
    When I exercise native working room "refine-growth"
    Then the native working-room observations include:
      """
      {"success":true,"at_least_three_resets":true,"authority_exact":true,"bounded":true,"replay_custody":true,"complete_package":true,"unsafe_not_retained":true,"red_observed":true,"one_candidate_readiness":true,"approval_revoked":true,"head_index_unchanged":true,"reset_events_valid":true}
      """

  Scenario: Refine resets cannot erase two invalid submissions
    When I exercise native working room "refine-invalids"
    Then the native working-room observations include:
      """
      {"reset_happened":true,"invalid_limit_preserved":true,"package_unchanged":true,"approval_unchanged":true,"head_index_unchanged":true}
      """

  Scenario Outline: Refine validates private history before publication or more inference
    When I exercise native working room "<mode>"
    Then the native working-room observations include:
      """
      {"reset_happened":true,"custody_refused":true,"no_inference_after_damage":true,"package_unchanged":true,"approval_unchanged":true,"head_index_unchanged":true}
      """
    Examples:
      | mode                   |
      | refine-damage-changed  |
      | refine-damage-missing  |
      | refine-damage-symlink  |
      | refine-damage-mode     |

  Scenario: Refine refuses irreducible exact authority before inference
    When I exercise native working room "refine-irreducible"
    Then the native working-room observations include:
      """
      {"irreducible_refused":true,"no_inference":true,"unsent_retained":true,"actionable_nonresume":true,"package_unchanged":true,"approval_unchanged":true,"head_index_unchanged":true}
      """

  Scenario: The complete JSON boundary is inclusive and reserve is unchanged
    When I exercise native working room "measure"
    Then the native working-room observations include:
      """
      {"bytes":[524287,524288,524289],"fits":[true,true,false],"reserve":[131072,131072,131072],"complete_rendered":true}
      """
