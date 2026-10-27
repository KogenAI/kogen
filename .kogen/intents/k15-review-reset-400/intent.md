# Validate Anthropic requests after a review reset

Slug: k15-review-reset-400
Model: not applicable — the change is request validation and a written loop-change note; it has no meaningful state machine
Acceptance:
- .kogen/intents/k15-review-reset-400/acceptance.feature
- features/steps/k15_review_reset_400_steps.js

Native review on the Anthropic route twice ended `provider/refused: Anthropic refused HTTP 400 … invalid_request_error` on the first request after `review local reset <N> -> <M> bytes` (KOGEN-066). Kogen cannot see why, because the vendored loop discards the provider's error message.

This Intent adds a fake Anthropic Messages validator (Go test helper in `cli/build`) that checks a rendered request the way the real API does, proves the post-reset request of a review is valid, proves the validator rejects the old/invalid shapes, and writes the loop-side change down instead of editing vendored bytes.

What the code does now (observed by a probe on the unchanged tree): `prepareContext("review", anthropic role, …)` over a conversation of thinking-carrying assistant messages, one of them with 30 parallel `tool_use` blocks, renders `messages` as user (opening), user (reset text), assistant (thinking + 30 tool_use), user (30 tool_result). This is exactly the refused index layout (`messages[3].content[29]`) and passes a structural check of ids, roles and breakpoints. So the static rules in the request are probably not the cause; the cause may only be knowable from the provider's message, which is loop-side. The builder must not assume a defect: build the validator, and if it exposes a real Kogen-side defect in `cli/build/context.go` (prepareContext/reset, newestExchange) fix it there with the smallest change; if not, the post-reset test is a regression guard and the loop note says the cause is unknown until the provider message is retained.

## Required work
1. Validator: a Go test helper in `cli/build` (e.g. `k15_anthropic_validator_test.go`) that, for a request body rendered by the real provider renderer (`b.bodyOf(role, instructions, input, tools, owner)` with `project.Role{Provider: "anthropic", Model: "claude-sonnet-5-5", Effort: "high"}`), returns an `invalid_request_error`-style error message for each violation of: (a) every `tool_result` block's `tool_use_id` has a `tool_use` with that id in the immediately preceding assistant message, and every `tool_use` has a `tool_result` in the immediately following user message, with `tool_result` blocks first in that message; (b) the first message is `user`, roles are user/assistant, no message or text block has empty content, and the last message is `user`; (c) at most 4 `cache_control` breakpoints in tools+system+messages combined; (d) an assistant message with `tool_use` that follows thinking being enabled starts with a `thinking` or `redacted_thinking` block that carries a nonempty `signature` (or data), and tool_use ids are unique. It may be served by an `httptest` server that answers 400 with `{"type":"error","error":{"type":"invalid_request_error","message":"<reason>"}}` or a valid stream, if the vendored client can target it without editing `cli/third_party`; otherwise validating the rendered body directly is enough.
2. Reset-then-continue test: build an Anthropic-shaped review conversation (items as the provider returns them: a `message` item carrying `anthropic_message` with a signed `thinking` block and `tool_use` blocks, followed by the matching `function_call` and `function_call_output` items; at least one exchange with 30 parallel calls), large enough that `prepareContext("review", …)` resets its working window (see `windowAttempt` in `context_test.go`), then validate the post-reset rendered body. Also cover a reset whose newest exchange is the 30-call batch.
3. Old-shape test: validate known-invalid post-reset shapes, at minimum the window that keeps the newest `function_call_output` items but drops the assistant message that holds their `tool_use` blocks, and any shape that was a real Kogen-side defect if one is found; the validator must reject each with a message naming the violated rule.
4. Loop note `docs/kogen-066-loop-change.md`: the exact loop change to request, because `cli/third_party/kogen-loop` must not be edited here. It must state: in `provider/respond.go` `messagesFailure` (Anthropic non-200) keeps only a known `error.type` and never the message; the change is to also keep `error.message` for 4xx refusals through the existing `hostMessage` sanitiser (one line, at most 300 bytes, saved key redacted, no request payload), so the existing `refusedError` prints `Anthropic said: …` and the `error.type` stays in the provider-failure diagnostics and attempt record; the same gap check for ChatGPT (`stream.go` failure with `message: detail`) must be stated with its finding after reading the code; the loop tests that assert the absence of the message (`provider/messages_test.go` cases `400`, `unknown type`, `not json` with `SECRET_BODY_TEXT`) must change to assert the bounded sanitised message, with a fake provider test that a 400 refusal shows the provider's message and no secret; and that Kogen then needs `packaging/sync-kogen-loop.sh` and a new `cli/loop-pin.json`.

## Boundaries
No new timeout, retry or limit. Review custody, pinned part delivery and the single commit are unchanged. Request bytes change only where a demonstrated defect fix needs it. No edit under `cli/third_party` and no change of `cli/loop-pin.json`. The probe-only file used while shaping is not part of the Intent.

## Decisions
- Loop-side changes are reported in `docs/kogen-066-loop-change.md`, not made (source: request)
- No retry, timeout or limit is added (source: request)
- The validator checks tool_use/tool_result pairing, role order, empty content, at most 4 cache breakpoints and thinking signatures (source: request)

## Source comparison
- Item 1 (keep provider `error.type` and a bounded sanitised message in the record and refusal text, Anthropic and ChatGPT): conflicting with "no edits under cli/third_party" because the message is dropped inside the vendored loop (`messagesFailure`); addressed as a precise loop change note, with acceptance that the vendored tree is untouched. Not implemented in this Intent (intent.md Required work 4).
- Item 2 (validating fake, reproduce reset-then-continue, fix post-reset request): addressed by the validator and tests (Required work 1-3). A probe showed the current post-reset request passes the structural rules, so a Kogen-side fix is conditional on the validator exposing a defect; no defect is invented.
- Item 3 (tests): reset-then-continue accepted and old shape rejected are addressed; the 400-shows-message test is loop-side and described in the note.
- Must stay: no new timeout/retry/limit, custody and commit unchanged, no vendored edits: addressed in Boundaries and the last scenario.
- Host safety: only synthetic keys and local servers in tests: addressed implicitly; no real credentials read.

## Tests
- Validator accepts valid requests and rejects each invalid shape: `TestK15ValidatorAcceptsValidAndRejectsInvalidShapes` (unit)
- Post-reset review request is valid for Anthropic: `TestK15ReviewResetThenContinueIsValidForAnthropic` (regression)
- Old/invalid post-reset shape is rejected by the same validator: `TestK15OldPostResetShapeIsRejected` (regression)
- Loop change reported precisely and vendored loop untouched: acceptance scenario 4 (scenario)
- Existing Build, context and provider tests keep passing: configured go-test check (existing)

## Feasibility
- A probe of `prepareContext("review")` on an Anthropic role with a thinking assistant message of 30 tool_use blocks followed by 30 tool_results produced messages user, user, assistant(thinking+30 tool_use), user(30 tool_result): the refused layout, structurally valid. (probe 1: exit 0, 5.3 s)
