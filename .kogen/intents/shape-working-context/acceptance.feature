Feature: Native Shape working continuity
  Background:
    Given the Shape continuity source packet:
      """json
      {
        "human_originals": {
          "human-steering-06.txt": "everything\nRewriting whatever is in Elixir in Kogen to Go",
          "human-steering-09.txt excerpt": "Bro why didn't shaping do proper job? that means we fucking aren't doing things properly in Kogen. Kogen shas to investigate everything it can't be retarded like that :/",
          "human-steering-14.txt": "Almir, 22 October 2026 (exact user message):\n\nI won't be there to check on you tonight, so please have some kind of 30 minute interval check for how it's going. But still, the old rules apply: you shouldn't interfere if possible and if you do make sure the Kogen is fixed so you don't have to in the future.",
          "human-steering-12.txt": "There are some more issues that we might want to handle that we disxcovered while trying some benchmarks\nAnyway, I'll be afk\nyou can handle all this stuff"
        },
        "observed_failure": {
          "slug": "go-core-migration", "scope": "whole Elixir core to Go", "provider": "ChatGPT", "model": "gpt-6.1-sol", "effort": "high", "installed": "kogen e53e0aa2", "seconds": 94.5, "request": 6,
          "error": "candidate/context_budget_exceeded: Complete next request 836778 bytes exceeds 524288; reserve 131072 tokens",
          "input_tokens_requests_2_to_5": [75281, 86017, 116574, 123102], "probes": 3, "documentation_lookups": 6, "tool_output_cap_bytes": 16384, "growth_source": "UNKNOWN",
          "evidence": "/Users/almirsarajcic/Areas/Kogen/studio-work/provider-subscriptions-20261022/go-migration-native/shape-1-context-exceeded/"
        },
        "benchmark_proposal_not_authority": {
          "confidence": "low; n=1; investigate, do not assume",
          "build": "f4637b88", "date": "21 Oct", "model": "Sol medium", "intent_lines": 73, "scenarios": 8, "elixir_lines": 10300, "go_lines": 2900, "exunit_lines": 6850, "seconds": 2326, "requests_approx": 85, "rounds": "12+", "stop": "context_exhausted", "near_input_tokens": 880000, "commit": false,
          "implementation": "roughly 15-20% code and about 5% acceptance outcomes, mostly unwired", "review": "GO-MIGRATION-REVIEW-20261021.md", "scenario_1": "beamPayloads: []", "passes_3_to_12": "not run because an earlier item failed: model, format, compile, test, go-test, spec, cucumber",
          "counterexamples": [
            {"id":"02788365", "input":"10.2M", "duration":"1h25m52s", "outcome":"landed"},
            {"id":"44e2eab6", "input":"552k", "duration":"20 min", "outcome":"landed"},
            {"id":"d61ff40f", "scope":"full UI", "seconds":3183, "outcome":"stopped at 17 of 18 scenarios"}
          ],
          "LOOP-9": {"commit":"71f7b4f", "time":"22 Oct 00:26 +03", "migration_scale":"untested in packet; one feature grepped"},
          "hypotheses_not_findings": ["may loop after reset", "fail-first gates hide later signals; mechanism-split-1 4 attempts 3/4 correct, 2/3 initial screen", "pass does not distinguish 1/8 from 7/8", "Shape did not signal independent pieces", "one-off lost library or four baseline failures"],
          "proposed_investigation_not_scope": ["script long Build across ceiling several times", "add scenario counts and per-check results on a local copy", "read old logs", "decide whether product change is needed"],
          "candidate_examples_not_commitments": ["kogen intent build big-feature; scripted ceiling crossings at rounds 4, 8, 12; log.jsonl resets owner/before/after/archive sha256; result.json landed or named stop with exact safe kogen intent resume <id>", "8 scenarios, 3 pass on pass 1; pass acceptance passed:3,total:8; kogen intent inspect <id> acceptance: 3/8 -> ..."],
          "open_questions_not_instructions": ["Is n=1 enough; what second case settles it?", "costly migration rerun is Almir's call"],
          "non_goals": ["automatic splitting", "size cap", "repair/stall stop; repair-stop-1 and blocker-stop-1 give no case", "resume parked migration Build", "Go migration itself", "caching", "Studio", "workers", "release", "deployment"]
        },
        "repair_boundaries": {"budget":524288,"reserve":131072,"deterministic":"no real providers or public internet","authority":"retain originals, source provenance, required literals, candidate-bound evidence, inspection and documentation gates","providers":["ChatGPT","SuperGrok","OpenCode Go"],"irreducible":"stop honestly; no universal immunity"},
        "fixture_question": "Which fixture label?", "fixture_answer": "1: Δ retained\n"
      }
      """

  Scenario: Continue mixed investigation and exact red acknowledgment
    When I exercise installed Shape windows "growth"
    Then the Shape window observations include:
      """json
      {"success":true,"at_least_three_resets":true,"bounded_requests":true,"event_contract":true,"authority_exact":true,"source_exact":true,"qa_exact":true,"complete_package":true,"unsafe_not_retained":true,"one_readiness_execution":true,"actual_red_observed":true,"documentation_retained":true,"three_probes":true,"archived_image_exact":true,"replay_custody":true,"checkout_authority_unchanged":true,"no_shape_approval":true}
      """

  Scenario Outline: Window changes do not bypass discovery or retry gates
    When I exercise installed Shape windows "<mode>"
    Then the Shape window observations include:
      """json
      {"gate_preserved":true,"reset_happened":true,"no_publication":true,"checkout_authority_unchanged":true,"bounded_requests":true}
      """
    Examples:
      | mode       |
      | inspection |
      | documents  |
      | invalids   |

  Scenario: Retain irreducible unsent authority rather than retrying
    When I exercise installed Shape windows "irreducible"
    Then the Shape window observations include:
      """json
      {"stopped_before_inference":true,"stop_custody_exact":true,"actionable_nonresume":true,"no_publication":true,"checkout_authority_unchanged":true}
      """

  Scenario Outline: Refuse damaged active Shape archive custody
    When I exercise installed Shape windows "<mode>"
    Then the Shape window observations include:
      """json
      {"reset_happened":true,"custody_refused":true,"no_inference_after_damage":true,"no_publication":true,"checkout_authority_unchanged":true,"bounded_requests":true}
      """
    Examples:
      | mode           |
      | damage-changed |
      | damage-missing |
      | damage-symlink |
      | damage-mode    |
