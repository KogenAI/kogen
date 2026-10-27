# Strip stale thinking blocks after a reset

Slug: k18-reset-thinking-binding
Model: not applicable — the change is a deterministic transformation of the kept messages at a reset; it has no state machine
Acceptance:
- .kogen/intents/k18-reset-thinking-binding/acceptance.feature
- features/steps/k18_reset_thinking_binding_steps.js

Build 581c4d38 (eea5864e, native Anthropic, review claude-opus-5-5/medium) logged `review local reset 759910 -> 378161 bytes` and the next request failed `Anthropic refused HTTP 400 … messages.1.content.0: Invalid signature in thinking block. The block is bound to a different conversation. Remove the block, or set thinking.block_binding.prefix_mismatch_behavior to "drop_block" (needs anthropic-beta thinking-binding-controls-2026-08-01)` (KOGEN-066/067). Evidence on eu2: `/home/delivery/src/kogen-kperf2/.kogen/local/runs/581c4d38/` (`log.jsonl`, `working-context/review/80.json`).

What the code does now: `prepareContext` in `cli/build/context.go` (build and review owners) returns `window.reduced` = mandatory opening + reset message + `newestExchange(in)`. The newest exchange holds provider-owned `message` items carrying `anthropic_message` (complete received assistant message, thinking signatures included). The vendored `provider/messages.go` replays those unchanged. A thinking signature is bound to the conversation prefix it was produced in; the reset changes the prefix, so the kept signatures are invalid.

## What to build
1. In `prepareContext`, when a reset happens, every kept item that carries `anthropic_message` (the assistant messages of the kept newest exchange) is replaced by a copy whose `anthropic_message.content` has no `thinking` and no `redacted_thinking` block. Do it inside the reset window construction (`construct`), so the measured request, the returned window, the checkpoint (`Continuation.Input`) and later rounds all hold exactly the stripped items; the private archive keeps the original input unchanged. All other blocks (text, tool_use) stay byte-for-byte in order; the `function_call` / `function_call_output` items are untouched, so tool_use/tool_result pairing stays valid. If no block remains in a message, that item is sent without `anthropic_message` (it then renders from its plain `role`/`content`). The input slice and items the caller holds are not mutated (copy). Items produced after the reset (appended by later rounds) keep their thinking blocks; a later reset strips them again like any kept message. Items without `anthropic_message` are never touched, so other providers are unaffected.
2. No change under `cli/third_party` and none to `cli/loop-pin.json`. The loop's replay-once rule is unchanged.
3. The binding-aware fake (a Go test helper in `cli/build`, e.g. `k18_binding_test.go`, extending the K15 validator `k15Validate`): it models the binding. It issues signatures: `k18Sign(body, i)` returns a signature that encodes a hash of the canonical JSON of `system`, `tools` and `messages[:i]` of the request the message was produced in, with every `cache_control` key removed before hashing. When validating a request, for every assistant message `i` and each `thinking` block with a signature, the signature must equal the one issued for the prefix `messages[:i]` of this request; otherwise it returns exactly `messages.<i>.content.<j>: Invalid signature in thinking block. The block is bound to a different conversation. Remove the block, or set thinking.block_binding.prefix_mismatch_behavior to "drop_block" (needs anthropic-beta thinking-binding-controls-2026-08-01)` (HTTP 400 text). A `redacted_thinking` block is checked the same way on its `data`. Test fixtures must produce their thinking signatures with this issuer against the body actually rendered by `b.bodyOf(...)` for the request that produced the message (exchanges are built incrementally), not with fixed strings.
4. K15 compatibility: K15's rule (d) required an assistant tool_use message to start with a thinking block. After stripping that is no longer true and is not required (see mechanism decision). Update `k15Validate` so that a first thinking block, when present, must be signed, and its absence is valid; remove the `no thinking first` case from `TestK15ValidatorAcceptsValidAndRejectsInvalidShapes` and keep every other case. The other K15 tests keep passing (their conversations use fixed signatures; run them through the K15 validator, not the binding check).

## Mechanism decision
Strip locally rather than send `thinking.block_binding.prefix_mismatch_behavior: "drop_block"` with `anthropic-beta: thinking-binding-controls-2026-08-01`. Reasons: the request prefers the option needing no beta header; the 400's own text names removal of the block as the first remedy; Kogen sends `thinking: {type: adaptive}` (profile `Settings.Reasoning`), under which the model decides whether to think, so a kept assistant tool_use turn without a thinking block is not a malformed request; and the kept turn's signature is bound to the old prefix and cannot be valid in the new conversation anyway, so keeping it is impossible under either mechanism. Honest limit: the documentation page could not be read through the documentation tool (the page is a script-rendered shell), so the absence of a documented "last assistant turn in a tool-use loop must carry thinking" rule for adaptive thinking is not independently confirmed; if the live API rejects stripped turns, the fallback is the drop_block option, which is out of scope here and not implemented.

## Must stay
No reset, round, retry or limit change. A request without a reset is byte-identical to today (the returned input is the input, and the rendered body equals the body rendered from it). Refusal-message handling from K15b stays.

## Decisions
- Strip `thinking` and `redacted_thinking` from kept provider-owned messages at a reset, no beta header (source: request)
- Strip inside the reset window construction so checkpoint, measurement and later rounds are consistent (source: request)
- The fake issues and verifies prefix-bound signatures and answers the exact 400 message (source: request)
- K15's thinking-first rule is dropped because adaptive thinking does not require it (source: request)

## Source comparison
- Item 1 (strip thinking/redacted_thinking from kept messages; text/tool_use byte-identical; pairing valid; post-reset messages keep thinking): addressed by What to build 1 and scenarios 2-4. `prepareContext` serves build and review; shape and refine windows are not changed (the request's "any owner" is addressed for the owners that replay `anthropic_message`; shape/refine not separately probed).
- Item 2 (choose mechanism, record why, prefer no beta): addressed in Mechanism decision; documentation could not be retrieved, stated as an honest limit.
- Item 3 (binding-aware validating fake with the exact message): addressed by What to build 3 and scenario 1. The vendored client cannot target a local host for Anthropic (fixed API base), so, as in K15, the fake validates the rendered body.
- Must stay: addressed in Must stay and scenarios 5, 7. Acceptance "same run on eea5864e's code fails with the 400" is realised as a control: the unstripped reset window (the old behavior) is fed to the same fake and must be rejected with the 400 message; the old binary itself is not run.
- Host safety: tests use synthetic data, local files only, no providers.

## Tests
- Binding fake accepts own-prefix signatures and rejects foreign ones with the exact message: `TestK18BindingFakeRejectsForeignSignatures` (unit)
- Review reset: stripped window accepted by the fake, unstripped window rejected (control), including a newest 30-call batch: `TestK18ReviewResetContinuesWithoutStaleThinking` (regression)
- Build-owner reset behaves the same: `TestK18BuildResetContinuesWithoutStaleThinking` (regression)
- Only thinking blocks removed, text/tool_use identical, caller items not mutated, post-reset responses keep thinking, second reset strips again: `TestK18ResetStripsOnlyThinkingAndKeepsNewConversationBlocks` (unit)
- No-reset request bytes identical for review and build: `TestK18RequestWithoutResetIsByteIdentical` (regression)
- K15 validator without the thinking-first rule and the other K15 tests keep passing: `TestK15ValidatorAcceptsValidAndRejectsInvalidShapes` (existing)
- No beta header or vendored edit: acceptance scenario 7 (scenario)
- Everything else: configured go-test check (existing)

## Feasibility
- none
