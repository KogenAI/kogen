# Strip stale thinking after Shape and Refine resets

Slug: k18b-shape-reset-thinking
Model: not applicable — a deterministic transformation of kept messages at a reset; no state machine
Acceptance:
- .kogen/intents/k18b-shape-reset-thinking/acceptance.feature
- features/steps/k18b_shape_reset_thinking_steps.js

K18 strips `thinking`/`redacted_thinking` blocks from kept provider-owned messages when a Build or Review working window resets (`stripStaleThinking` in `cli/build/context.go`, used in `prepareContext`). Native Shape and Refine were left out. A native Anthropic shape (kogen 973a8c4, claude-sonnet-5-5 medium, 25 requests, 698 s) failed with the same 400: `messages.1.content.0: Invalid signature in thinking block. The block is bound to a different conversation`.

What the code does now: `window.prepare` in `cli/shape/window.go` (used by Shape at `shape.go` and Refine at `refine.go`) returns `mandatory + newestWindowExchange(input)` on a reset, keeping provider-owned items with `anthropic_message` unchanged, so their thinking signatures are bound to the old prefix. Shape workers (optional) do not use a window or keep provider-owned messages across resets, so nothing changes for them.

## What to build
1. Move `stripStaleThinking` out of `cli/build` into a new shared non-test package `cli/thinking` as exported `thinking.Strip(items []any) []any` (same behaviour as today). `cli/build` uses it (no private copy remains) and `cli/shape` uses it. No other non-test Go code outside `cli/third_party` may handle `redacted_thinking`.
2. In `window.prepare` (`cli/shape/window.go`), the reset's reduced input becomes `mandatory + thinking.Strip(newestWindowExchange(input))`, so measurement, the returned input, and later rounds hold the stripped items; the private archive still stores the original `input` unchanged. This serves Shape and Refine alike. Other blocks byte-for-byte and in order; function_call/function_call_output untouched; a message left with no blocks loses `anthropic_message`; caller items are not mutated; items produced after the reset keep their thinking (a later reset strips them again); items without `anthropic_message` are untouched.
3. Tests (Go, names fixed because the acceptance runs them by name and requires an explicit pass):
   - `cli/thinking`: `TestStripThinkingKeepsOtherBlocksAndDoesNotMutate` (thinking and redacted_thinking removed; text/tool_use identical; thinking-only message loses `anthropic_message` and renders from plain `content`; input slice and items unmutated; items without `anthropic_message` returned unchanged). Move the existing thinking-only assertion of `TestK18ResetStripsOnlyThinkingAndKeepsNewConversationBlocks` to call `thinking.Strip`.
   - `cli/shape`: `TestK18bShapeResetContinuesWithoutStaleThinking` and `TestK18bRefineResetContinuesWithoutStaleThinking`: extend K18's binding-aware fake to Shape/Refine, with the same semantics as `k18Sign`/`k18Validate` (signature = hash of canonical JSON of system, tools and `messages[:i]` with `cache_control` removed; a thinking `signature` or redacted_thinking `data` not equal to the issued one for its own prefix gives exactly `messages.<i>.content.<j>: Invalid signature in thinking block. The block is bound to a different conversation. Remove the block, or set thinking.block_binding.prefix_mismatch_behavior to "drop_block" (needs anthropic-beta thinking-binding-controls-2026-08-01)`). Build an incremental conversation whose signatures are issued against the Anthropic body actually rendered for the request that produced each message (render with the same provider message rendering the real Shape/Refine requests use; do not use fixed strings), run it through `window.prepare` with a window that makes the reset happen (as `window_test.go` does for Shape via `newShapeWindow` and for Refine via `newRefineWindow`, newest exchange including a multi-call batch), and require: the reduced request validates with the fake; the control (reduced input with the original unstripped newest exchange) is rejected with the binding message; the caller input is unmodified; the archive holds the original unstripped input. The fake may be a test helper in `cli/shape` or a shared test-only helper, but `cli/build`'s K18 tests must keep working; a second copy of the stripper is not allowed (only the test validator may be repeated).
   - `cli/shape`: `TestK18bShapeAndRefineRequestWithoutResetIsByteIdentical`: for a fitting conversation holding signed thinking messages, `prepare` returns the input itself (deep-equal) and the rendered body is byte-identical to the body rendered from the input, for the Shape window and the Refine window.

## Must stay
No reset, round, retry, limit, archive, handoff or event change. Requests without a reset byte-identical. K18 behaviour for Build and Review unchanged (existing K18/K15 tests keep passing). No edit under `cli/third_party` or `cli/loop-pin.json`; no beta header or `drop_block` option.

## Decisions
- Strip locally at Shape and Refine resets exactly as K18 does, one shared `thinking.Strip` (source: request)
- Shape workers need no change because they keep no window (source: request)
- The binding-aware fake is extended to Shape and Refine resets with the control that the unstripped window is rejected (source: request)

## Source comparison
- Item 1 (strip at Shape/Refine resets, same guarantees; workers if they keep provider messages): addressed by What to build 1-2; workers do not (no `windowPrep` use), stated.
- Item 2 (reuse `stripStaleThinking`, shared place): addressed by `cli/thinking.Strip` and acceptance scenario 6 (single holder of `redacted_thinking`, imported by both packages).
- Item 3 (extend binding-aware validator): addressed by the two shape tests and scenarios 2-3.
- Must stay: scenarios 4-6 and Must stay. Acceptance bullets: shape/refine reset continues and unstripped rejected (scenarios 2-3), no-reset byte-identical (scenario 4), all configured checks via the build's checks.
- The live provider is not called; the fake validates the rendered body as in K18. Host safety: synthetic data, no processes stopped, no real provider calls.

## Tests
- Shared stripper behaviour: `TestStripThinkingKeepsOtherBlocksAndDoesNotMutate` (unit)
- Shape reset continues against the binding fake, unstripped rejected: `TestK18bShapeResetContinuesWithoutStaleThinking` (regression)
- Refine reset likewise: `TestK18bRefineResetContinuesWithoutStaleThinking` (regression)
- No-reset request unchanged for Shape and Refine: `TestK18bShapeAndRefineRequestWithoutResetIsByteIdentical` (regression)
- Build/Review unchanged: K18 tests in `cli/build` (existing)
- Single shared implementation, no vendored edit: acceptance scenario 6 (scenario)
- Everything else: configured go-test check (existing)

## Feasibility
- none
