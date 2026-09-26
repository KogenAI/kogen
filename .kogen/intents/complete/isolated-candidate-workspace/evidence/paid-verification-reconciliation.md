# Paid verification reconciliation

Retained Build record `.kogen/runtime/scenario-tracking/Zi1QBLqbAFvZqdOkAyhrAjdk/record.json` passed `check` and `cold-offline` in all three cycles. `live-native` passed twice and failed once. `live-reviewer-rework` failed twice, and `live-shape-to-build` was never reached before retry exhaustion.

Direct focused runs reproduced the missing boundaries. `mix test --only live test/kogen/live_reviewer_rework_test.exs` failed in about five seconds because `test/support/live_reviewer_rework_fixture.ex` called `Kogen.CompiledFixture.prepare_build!/2` without loading the script-backed module. In parallel, `mix test --only live test/kogen/live_shape_to_build_test.exs` failed after about 254 seconds because ordinary `_build/lib/file_system/priv` is a relative symlink and the prior contract rejected every seed symlink. Retained connected evidence is under `.kogen/runtime/live-evidence/shape-to-build-7896-6-1790051240248112167`.

A requested Fable-medium read-only review confirmed that normal Mix `_build` trees contain relative `priv`, `include`, and `src` links; the strict rule made real workspace admission impossible. It recommended preserving only relative links whose lexical and resolved targets stay in the corresponding project tree, rejecting absolute, dangling, escaping, runtime-targeting and retargeted links, and adding provider-denied focused coverage that loads the actual selected live owners and fixtures.

The Shaper additionally directed that the Intent tell the Developer which tests are causally related to its work so those tests can be run repeatedly during implementation. The amended scenario proof maps serve that purpose. Stop remains responsible for the real full suite and paid boundaries.
