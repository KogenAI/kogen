# Accept complete Anthropic end-turn tool batches

Slug: anthropic-complete-tool-turn
Model: .kogen/intents/anthropic-complete-tool-turn/model.qnt invariants=NoPartialCalls,ExactMarker seed=59 samples=100 steps=5
Acceptance:
- .kogen/intents/anthropic-complete-tool-turn/acceptance.feature
- features/steps/anthropic_complete_tool_turn_steps.js
- features/steps/go_driver_support.js

Repair KOGEN-059: after the complete Anthropic Messages stream and every block have passed existing validation, a nonempty tool batch is actionable under either `end_turn` or `tool_use`. This replaces only the final classifier's rejection of valid tool batches under `end_turn`. Text may accompany the calls but is not required. Amend the native Anthropic paragraph in `spec/prose/08-chatgpt.md` accordingly, and update affected implementation tests in `cli/provider/messages_test.go`; implementation includes `cli/provider/messages.go` and safe metadata/attempt-record plumbing in `cli/provider/respond.go` as needed. None of these implementation files is protected by this Intent.

Technical settlement: successful Anthropic attempt records gain top-level `anthropic_stop_reason` (the recognized terminal string) and `anthropic_end_turn_tool_use` (a JSON boolean, true iff this successful completion ended with end_turn and exposed a nonempty validated tool batch). Ordinary tool_use and text-only end_turn record false. Failed Anthropic attempts record null/false, not an inferred successful reason. Keep fields Anthropic-specific; do not add them to other providers. Preserve the safe id/model sanitizer, but do not run the boolean through an identifier sanitizer or copy arbitrary response metadata into analytics. No retry, fallback, configuration knob, dependency or reading mechanism is introduced.

The finite model abstracts whole-stream assembly/validation into complete/valid predicates, call count (0/1/2), text presence and terminal reason. It checks atomic exposure and exact marker semantics, not network framing or replay implementation.

## Decisions
- Accept a stream ending with message_stop, stable stop_reason end_turn, and one or more fully valid tool_use blocks exactly as the otherwise identical tool_use completion (source: request)
- Keep validation before exposure of any call: contiguous indexed blocks, strict JSON-object inputs, valid nonblank ids/names, unique tool ids, thinking signatures, redacted-thinking data, and rejection of unknown/server-tool blocks. A valid first call never licenses an invalid later block (source: request)
- Keep cut/unreadable streams transient under the existing bounded retry policy. Malformed complete frames, error events, actionable events after message_stop, changed stop reasons, max_tokens, refusal, pause_turn and stop_sequence remain invalid. model_context_window_exceeded remains context_too_long. Empty end_turn remains invalid and useful text-only end_turn remains valid (source: request)
- Retain opaque ordered thinking/signature/redacted-thinking/text/tool_use replay once, and group matching tool_results in the following user message. Preserve working windows, checkpoints, operation budgets, context limits, cache controls, keys/accounts and every other provider (source: request)
- Record only safe structural fields, never response text or keys, and provide a countable marker for the newly accepted case (source: request)
- Use only deterministic local scripted servers, including one installed packaged-release Build that lands. No live provider call or claim of general correctness, savings, rate-limit benefit or model qualification (source: request)

## Source comparison
- addressed: request §1 and §2 prioritize efficient file reading/context after delivered caching; this Intent is solely the selected reliability prerequisite, not a new reading/caching implementation. No Claude Code collaboration/service or live-account qualification is introduced.
- addressed: request §2, §4 and §7; the synthetic regression preserves msg_synthetic_01, claude-sonnet-5-5, toolu_synthetic_01, read_file, lib/helper.go, supplied thinking/signature and usage (12/48000/300/812), streams deltas and message_stop, and compares end_turn with tool_use. Acceptance's one/rich cases and installed Build distinguish old rejection from actionable calls.
- addressed: request §3 is historical evidence (nine failures/four tasks, 3/10 in two rounds, 580–1,095 output tokens, no captured error/cut/order fault; narrow external experiment is not qualification). No prevalence or timing claim becomes an acceptance oracle. Local acceptance proves only actual scripted outcomes.
- addressed: request §5 and §7 validation/stream counterexamples are exercised independently in the rejection Outline, with a valid call preceding invalid later blocks. Existing provider tests remain useful and must not be weakened. Rich replay covers multiple calls, signed thinking, redacted thinking and text; packaged Build observes real execution, fresh checks, independent Review and a landed commit.
- superseded: request §6 / spec/prose/08-chatgpt.md lines 259–262 currently allow only useful end_turn text or tool_use batches. Amend to also permit complete validated end_turn tool batches; all surrounding validation/refusal/replay guarantees stay in force.
- addressed: request §2/§5 recording uses the structural fields defined above; acceptance expects stop reason and boolean on successful completions, null/false on failures, and no response text/signature/key leakage. Field names and failure defaults are technical settlement, not supplied wire fields.
- omitted deliberately as out of scope: request §7 exclusions—HTTP 400 body retention, retries, other-provider changes, reading/context/ledger/compaction/default changes. Existing transient retries (three attempts, 2s/8s) remain unchanged; no retry is added for this successful case.
- addressed: original reproducible and negative inputs are in executable acceptance and its owned step fixture; expected observable values are in acceptance.feature. Mapping is diagnostic, not proof of complete semantic coverage.

## Tests
- Completed end_turn tool batches become actionable without text, including multiple calls: add focused parseMessages regression tests and supplied streamed delta regression (regression)
- No call escapes before whole-batch validation: extend TestAnthropicCompleteValidationPrecedesExposingAnyCall to both allowed reasons and preserve invalid-block cases (unit)
- Cut/unreadable, malformed/error/order faults and disallowed reasons keep existing effects and retry bounds: rejection Outline and existing Anthropic stream/retry tests (integration)
- Empty end_turn fails while text-only end_turn and ordinary tool_use succeed: explicit acceptance cases and existing parser tests (regression)
- Successful attempts retain stop reason and exact boolean marker without payload leakage; failures are null/false: add Client.Respond attempt-record tests including type-aware safe metadata handling (integration)
- Exact ordered opaque replay and grouped matching tool_results survive the accepted completion: existing claude-api-key driver through Client.Respond, agent.Replay and JSON save/reload with one and rich streams (integration)
- Packaged CLI executes the accepted call, continues to edit, verifies, independently reviews and lands once: installed scripted-server Build (scenario)
- Other-provider routing, cache policy, windows/checkpoints, budgets, credentials and context guards remain unchanged: preserve configured regression checks (existing)
- Native Anthropic prose no longer contradicts end_turn tool success: amend adapter contract and affected tests without weakening surrounding checks (existing)

## Feasibility
- Documentation discovery returned retrieved search results but no useful technical source for the two queries. Fetches of https://platform.claude.com/docs/en/build-with-claude/streaming and its .md form returned retrieved, truncated, untrusted data. The latter describes SSE flow, cumulative usage and object tool inputs; neither is trusted confirmation of end_turn tool support. The request defines compatibility behavior; no paid capability assertion is made.
- Local toolchain probe observed Go 1.27.2, Node v24.21.0 and successful compilation of the existing claude-api-key driver. First model probe failed on missing parentheses; corrected model typecheck and TypeScript run passed (seed 59, 100 samples, 5 steps; probe 2 exit 0, 0.6 s). This abstraction check is not implementation proof.
- Focused packaged-fixture control changed only the first scripted stop reason to tool_use, leaving production unchanged: observed exit 0, four requests, executed read, candidate file, successful verification, independent Review and one landed commit (probe 3: exit 0, 20.0 s). A separate unchanged end_turn fixture observed one request and Build exit 4 with provider/invalid_response (probe 4: diagnostic command exit 0, 17.3 s). respond.go deliberately renders every Anthropic resInvalid as malformed Anthropic completion, including the final classifier rejection. These scratch controls establish fixture viability, not end_turn implementation success or final-byte observer qualification.
- evidence: {"id":"tool-turn-observer","kind":"observer","inputs":["features/steps/anthropic_complete_tool_turn_steps.js"],"observers":["features/steps/anthropic_complete_tool_turn_steps.js"],"checks":[{"name":"good","command":"\"$KOGEN_NODE\" features/steps/anthropic_complete_tool_turn_steps.js control good","exit":0,"output":"accepted\n"},{"name":"bad","command":"\"$KOGEN_NODE\" features/steps/anthropic_complete_tool_turn_steps.js control bad","exit":1,"output":"rejected\n"}]}
