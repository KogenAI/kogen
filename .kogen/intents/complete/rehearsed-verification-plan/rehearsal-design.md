# Executable rehearsal design

The catalog's `rehearsal` value is an object, not a symbolic label. Each provider-backed target declares `id`, exact `command`, `shared_entrypoints`, `correct_fixture`, `wrong_fixture`, and `trace_assertions`. `check` enumerates the catalog and executes every command with provider denial active. It fails if a command is absent, orphaned, selects nothing, dispatches native/provider transport, or omits a declared trace.

| target | rehearsal command/owner | required shared route and controls |
| --- | --- | --- |
| `live-shape-to-build` | focused future-Build lifecycle rehearsal under `test/kogen/verification_ownership_lifecycle_test.exs` | Real contract/context/Stop-state/receipt consumer route; launch plus repair-resume correct control; fixed one-capture wrong control; terminal settlement trace. |
| `live-reviewer-rework` | focused same-Developer rework rehearsal under `test/kogen/two_outer_resumptions_test.exs` | Real handoff/review/rework consumer and fresh-Review audit; reused Reviewer/wrong Developer controls. |
| `live-general` | paired scenario-semantic fixture under `test/kogen/scenario_semantic_test.exs` | Real Reviewer output schema and `Kogen.ScenarioSemantic` consumer; plausible complete-looking wrong output and correct output, without expected answer in agent-visible input. |
| `live-shaping-quality` | maintained offline driver rehearsal under `test/kogen/shaping_evaluation_test.exs` | Real preparation, selector, response parser, draft audit and evidence-manifest consumer; malformed/partial and correct paired cases. |
| `live-native` | compatibility preparation, discovery/native receipt fixtures, and `live_native_receipt_audit_test.exs` | Real environment preparation and receipt/audit consumers with fake transport; XDG null/empty, control-root precondition, empty selection, orphan receipt, and capture-count drift controls. |

Shared-entrypoint proof is runtime trace data emitted by the production function boundary into test-owned temporary state, not a source-text search. Correct and wrong fixtures traverse the same named entry points; only fake transport output differs. The owner means the catalog target, even when several live test files implement that target.

Catalog completeness also binds each live Make recipe and owner file exactly once. A Candidate that merely copies a production parser or lists a test file as `rehearsal_selector` fails because no executable command, paired fixtures, or shared-entrypoint trace exists.
