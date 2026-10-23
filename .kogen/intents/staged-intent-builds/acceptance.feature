Feature: One approved Intent with durable verified stages
  Background:
    Given the native staged fixture contract is:
      """json
      {
        "request": "What's the solution for this? Big intents get split into multiple smaller ones, or can intents have stages? Or some third solution?\n\nSo for this huge Go rewrite, what would that look like?\n\nok so we first fix Kogen, then use that for this multi-stage rewrite?\n\nYes. Plese, let's not lose all this valuable code. You can use probably worktree for Go rewrite, right?\n\nJust to make it clear: shaping will figure out whether an intent needs multi-stage build, right? And then how does that look like when one approved intent is passed to the build phase?\n\nFixture scope: implement native staged Builds, NOT the Go migration. One approval, durable verified stage progress, complete final acceptance/model/configured checks and fresh independent whole review, then one commit. Substantive plan changes need native Refine and fresh exact approval. No-plan behavior stays unchanged. Keep 524288 inclusive bytes and 131072-token reserve, exact authority/history/literals/tool pairs/opaque replay and honest refusals. No cross-path Resume, old approval/check replay, stash import, guard increase or external source patch. Studio, release/deployment, approval-card recovery and Claude API provider are out of scope. Core operator remains the same; Studio operator is independent. Deterministic fixtures are local only.\n\nHistorical source data, NOT fixture success: go-core-migration root c1c527a8; resumes ea8ea4d7, 8442fc98, 6fbbd2d5; about five hours and 14 passes failed at Go migration not implemented: lib remains; configured checks not reached; three overload stops and final ChatGPT sign-in refresh failure. Preserve failed/unknown usage and external authorship. The inspected last result has reviews 0 and unknown_requests 4. 594 files and one deletion are preserved, with a named stash and exact reference worktree /Users/almirsarajcic/Areas/Kogen/worktrees/go-core-migration-staged, NOT a new checkpoint. Do not read or modify it from tests. Delivered prerequisites to retain: 44c2e06d, 65640c64, 0e43500b (KOGEN-048), a6a1083f, 2137fa9b (KOGEN-047), 48bc5efc, 71dd6da1. The earlier 538761-byte read was a real prior defect, not permission to raise guards. Qualify this capability before a separate fresh staged Go reconciliation/build using preserved reference code and new exact approval; do not execute that follow-on here.",
        "plan": {
          "version": 1,
          "stages": [
            {"id":"foundation","title":"Foundation","goal":"Establish the first runnable section","checks":["\"$KOGEN_NODE\" features/steps/gate.cjs stage-one"]},
            {"id":"surface","title":"Surface","goal":"Integrate the second section","checks":["\"$KOGEN_NODE\" features/steps/gate.cjs stage-two"]}
          ]
        }
      }
      """

  Scenario: Repair scoped work, resume durable progress, then deliver the whole Intent
    When I exercise native staged Builds in mode "flow"
    Then the native staged observations are:
      | shape_ok                 | true |
      | shape_request_exact      | true |
      | shape_guidance           | true |
      | card_plan                | true |
      | first_stopped            | true |
      | stop_index_approval      | true |
      | stage_progress           | {"total":2,"completed":["foundation"],"active":"surface","phase":"stage"} |
      | stage_trace              | [{"kind":"stage-one","state":"broken","status":1},{"kind":"stage-one","state":"phase-one","status":0},{"kind":"stage-two","state":"phase-two","status":0}] |
      | stage_records            | [{"stage_id":"foundation","green":false},{"stage_id":"foundation","green":true},{"stage_id":"surface","green":true}] |
      | no_full_before_stop      | true |
      | no_review_before_stop    | true |
      | resume_exact             | true |
      | first_result_unchanged   | true |
      | effect_once              | true |
      | final_trace              | ["phase-two","final","review-broken","final-reviewed"] |
      | model_executed           | true |
      | configured_final         | true |
      | reviewer_repair_feedback | true |
      | independent              | true |
      | landed                   | true |
      | commits                  | "1" |

  Scenario Outline: Unsafe continuation does not turn a milestone into authority
    When I exercise native staged Builds in mode "<mode>"
    Then the native staged observations are:
      | first_stopped          | true |
      | stage_progress         | {"total":2,"completed":["foundation"],"active":"surface","phase":"stage"} |
      | refused                | true |
      | refusal_unchanged      | true |
      | no_model               | true |
      | first_result_unchanged | true |
      | commits                | "0" |
    Examples:
      | mode            |
      | candidate-drift |
      | plan-drift      |
      | other-checkout  |

  Scenario: A substantive plan correction revokes rather than transfers approval
    When I exercise native staged Builds in mode "refine"
    Then the native staged observations are:
      | card_plan            | true |
      | refined              | true |
      | revoked              | true |
      | build_needs_approval | true |
      | changed_card         | true |
      | no_commit            | true |

  Scenario Outline: Invalid stage plans cannot be approved as ignored prose
    When I exercise native staged Builds in mode "invalid:<case>"
    Then the native staged observations are:
      | invalid_refused   | true |
      | no_model          | true |
      | invalid_unchanged | true |
      | no_approval       | true |
    Examples:
      | case        |
      | empty       |
      | duplicate   |
      | blank-check |
      | version     |

  Scenario: An unstaged Intent still goes straight through the ordinary whole gate
    When I exercise native staged Builds in mode "single"
    Then the native staged observations are:
      | shape_ok    | true |
      | landed      | true |
      | commits     | "1" |
      | stage_trace | [] |
      | final_trace | ["final"] |
