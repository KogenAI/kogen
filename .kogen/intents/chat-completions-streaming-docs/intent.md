# Correct the Chat Completions streaming guidance

Slug: chat-completions-streaming-docs
Model: not applicable — the change is one documentation sentence and the test that checks it; there is no state
Acceptance:
- .kogen/intents/chat-completions-streaming-docs/acceptance.feature
- features/steps/chat-completions-streaming-docs__steps.js

The provider guide `docs/providers.md` says the Chat Completions route does not stream, that a reply arrives whole, and that a 45 seconds first-byte watchdog applies. The vendored route sets `"stream": true` in its request body, and `cli/loop_chat_streaming_test.go` shows a streamed answer succeeding after a first byte that arrives 60 simulated seconds late. The guide and its Go test must match that behavior.

Scope: `docs/providers.md` and `cli/providers_guide_test.go`. Out of scope: provider transport behavior and watchdog configuration; nothing under `cli/third_party/` changes.

The obsolete sentence on the last line of the QwenCloud section is replaced by one sentence saying the Chat Completions route streams its reply and that a first byte that arrives 60 seconds late is still waited for. The whole-reply claim and the 45-second first-byte claim are removed from the page, with no other line of the page changed. In `cli/providers_guide_test.go`, `TestProvidersGuideKeepsTheQwenCloudFacts` stops requiring "does not yet stream", requires the new sentence, and fails when the page contains any of the obsolete wordings.

## Decisions
- The replacement sentence is `The Chat Completions route streams its reply, and a first byte that arrives 60 seconds late is still waited for.` It replaces the obsolete line in place, and no 45-second or other first-byte figure is stated, because the test demonstrates only that 60 seconds is waited for and watchdog configuration is out of scope. (evidence: docs/providers.md; cli/loop_chat_streaming_test.go; cli/third_party/kogen-loop/provider/chat.go) (source: request)
- The existing `TestProvidersGuideKeepsTheQwenCloudFacts` is updated rather than adding a new test: its required list swaps "does not yet stream" for the new sentence, and a loop fails on the obsolete wordings "does not yet stream", "arrives whole", "45 seconds" and "45-second". (evidence: cli/providers_guide_test.go) (source: request)
- Acceptance observes the real page and runs the compiled provider guide Go tests against the real page and four mutated pages (obsolete sentence restored, streaming sentence removed, whole-reply claim added, 45-second claim added), restoring the page afterwards, so it does not depend on new test names. (evidence: cli/providers_guide_test.go) (source: request)
- Change `docs/providers.md` line 47 and `cli/providers_guide_test.go` only, as above. (decision: D1, round 1) (constraint: no change under cli/third_party/) (constraint: no other line of docs/providers.md changes) (evidence: docs/providers.md; cli/providers_guide_test.go; cli/loop_chat_streaming_test.go) (assumption: the 60-second wording is the intended description of the first-byte wait; I ran the compiled provider guide tests and applied the control patches in a scratch copy, but Kogen readiness has not yet confirmed them) (source: request)

## Source comparison
- Request: the guide describes Chat Completions as streaming and removes the whole-reply and 45-second first-byte claims — addressed in `docs/providers.md`, checked by acceptance scenario 1.
- Request: the guide test checks the updated streaming guidance and no longer requires the obsolete wording — addressed in `cli/providers_guide_test.go`, checked by acceptance scenario 2.
- Request: the first-byte wait demonstrated by the test (60 simulated seconds) — described in the new sentence.
- Request: provider transport behavior and watchdog configuration are out of scope — untouched.

## Tests
- The page describes Chat Completions as streaming and has no whole-reply or 45-second claim: update `TestProvidersGuideKeepsTheQwenCloudFacts` in `cli/providers_guide_test.go` (unit)
- The test enforces the streaming sentence and rejects the obsolete wordings: the acceptance scenario runs the compiled test against the page and mutated pages (scenario)
- The streaming and 60-second first-byte behavior itself stays proven: `cli/loop_chat_streaming_test.go` (existing)

## Feasibility
- none
