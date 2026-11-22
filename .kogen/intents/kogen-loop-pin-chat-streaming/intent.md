# Prove vendored Kogen Loop streams Chat Completions

Slug: kogen-loop-pin-chat-streaming
Model: not applicable — the change adds one Go test file and has no state to model
Acceptance:
- .kogen/intents/kogen-loop-pin-chat-streaming/acceptance.feature
- features/steps/kogen-loop-pin-chat-streaming__steps.js

The vendored kogen-loop under cli/third_party/kogen-loop (pinned by cli/loop-pin.json) already carries kogen-loop@b05fcf4 (Stream Chat Completions responses). This change proves that from the CLI package with exactly one new Go test file in cli/ (package main), which the Build writes. The test file does two things: it reads cli/third_party/kogen-loop/provider/chat.go and fails unless the Chat Completions request body sends "stream": true (and fails on "stream": false); and it runs the vendored provider Chat Completions client (an openai-compatible role whose base URL is a loopback httptest server) with a simulated clock, against a fixture server that delays its first byte by 60 seconds of simulated time and then streams a short answer, and requires the call to succeed with one request (a 45 second first-byte watchdog must not fire). Nothing else changes: cli/third_party/kogen-loop, cli/loop-pin.json, cli/go.mod and cli/go.sum are protected and untouched, loop_pin_test.go is unchanged and still passes, and existing CLI tests keep passing. No setting, flag or production code is added.

## Decisions
- Add exactly one new Go test file directly in cli/ and change no other file outside the Intent's own artifacts; the vendored copy, pin, go.mod and go.sum stay untouched (evidence: cli/loop_pin_test.go) (source: request)
- The body check reads cli/third_party/kogen-loop/provider/chat.go as text and requires "stream": true and no "stream": false, because the vendored renderer already sends "stream": true (evidence: cli/third_party/kogen-loop/provider/chat.go) (source: request)
- The slow-first-byte fixture uses the exported provider.Client with a simulated Now/Sleep clock and a loopback server that advances that clock by 60 s before its first byte; the vendored default header wait is 120 s, so only a copy with a 45 s wait fails it (evidence: cli/third_party/kogen-loop/provider/idle.go) (assumption: the Build keeps the fixture's real-time hold of a few seconds so the watchdog, which polls about once a second, reads the simulated clock) (source: request)
- Acceptance cannot name the Build's new tests, so the step finds the one new Go file in cli/, runs the Test functions it defines, and proves it is not a false pass by running the same tests in a temporary copy of cli/ whose vendored chat.go sends "stream": false and again with a 45 s header wait; both must fail (evidence: cli/third_party/kogen-loop/provider/idle.go; cli/third_party/kogen-loop/provider/chat.go) (source: request)
- The pin test stays untouched: the step checks loop_pin_test.go's digest and that TestLoopPin reports PASS and is not skipped (evidence: cli/loop_pin_test.go) (source: request)
- Add exactly one new Go test file in cli/; protected vendored copy, pin, go.mod and go.sum untouched (decision: D1, round 1) (evidence: cli/loop_pin_test.go) (assumption: none) (source: request)
- Body check reads vendored chat.go as text; vendored chat.go already sends stream true (decision: D2, round 1) (evidence: cli/third_party/kogen-loop/provider/chat.go) (assumption: none) (source: request)
- Slow first byte fixture uses provider.Client with simulated clock and loopback server; default header wait 120s so only a 45s copy fails (decision: D3, round 1) (evidence: cli/third_party/kogen-loop/provider/idle.go) (assumption: The scratch run showed the correct test passing and both mutations failing, but this session's runs are not retained by Kogen.) (source: request)
- Acceptance discovers the single new Go test file and runs its tests, mutating a temp copy of cli/ to prove it is not a false pass (decision: D4, round 1) (evidence: cli/third_party/kogen-loop/provider/idle.go; cli/third_party/kogen-loop/provider/chat.go) (assumption: none) (source: request)
- Pin test is checked by digest and PASS-not-SKIP of TestLoopPin (decision: D5, round 1) (evidence: cli/loop_pin_test.go) (assumption: none) (source: request)

## Source comparison
- Check 1 (reads vendored chat.go, fails unless "stream": true; wrong: test that does not read the file or accepts false): addressed by scenario "The Chat Completions request body sends stream true" and controls wrong 1 and 2.
- Check 2 (60 s simulated first byte then streamed answer succeeds; wrong: 45 s watchdog firing): addressed by scenario "A first byte 60 seconds late still succeeds" and controls wrong 3 and 4.
- Check 3 (existing pin test passes; wrong: skipped or weakened): addressed by scenario "The existing pin test still passes against the refreshed tree" and control wrong 5.
- Constraint: no change outside one new Go test file in cli: addressed by the scope step.

## Tests
- The Chat Completions request body sends "stream": true: new Go test in cli/ reading the vendored chat.go (scenario)
- A first byte 60 seconds late still succeeds and streams: new Go test in cli/ running the vendored client against a loopback fixture with a simulated clock (integration)
- The pin test still passes: existing TestLoopPin in cli/loop_pin_test.go (existing)

## Feasibility
- none
