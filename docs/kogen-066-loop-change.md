# KOGEN-066: loop change to request (not made here)

Native review on the Anthropic route ended `provider/refused: Anthropic refused HTTP 400 … invalid_request_error`
on the first request after a `review local reset`. Kogen cannot tell why: the vendored loop discards the
provider's message. `cli/third_party/kogen-loop` must not be edited in this repository, so the change is
written down here for the loop's own repository.

Kogen-side finding: the rendered post-reset request (user, reset text, assistant with signed thinking and 30
`tool_use`, user with 30 `tool_result`) passes the fake Messages validator in
`cli/build/k15_anthropic_validator_test.go` (tool_use/tool_result pairing, roles, empty content, at most 4
breakpoints, thinking signatures, unique ids). No Kogen-side defect was found; the cause is unknown until the
provider message is retained.

## Change: Anthropic (`provider/respond.go`, `messagesFailure`)

On a non-200 response `messagesFailure` keeps only a known `error.type` and never the message. Also keep
`error.message` for 4xx refusals (not 401/429/5xx, which keep their present handling) in `failure.message`
through the existing `hostMessage` sanitiser: one line, at most 300 bytes, the saved key redacted, no request
payload. The existing `refusedError` then prints `Anthropic said: …`, and `error.type` stays in the
`provider failure: {…}` diagnostics and the attempt record. It is a one-line change in `messagesFailure`:
`f.message = hostMessage(<error.message string>, key)` next to the `error.type` handling.

## ChatGPT (`provider/stream.go`, `httpFailure`)

Checked after reading the code: `httpFailure` already keeps the message (`message: detail`, taken from
`error.message`, then `error.code`, `detail`, or the first 200 runes of the body) and `failure.classified`
prints it in `<label> refused the request: <status> <message>`. There is no drop to fix. The gap is that this
text is not passed through `hostMessage` (it is neither single-line, nor limited to 300 bytes, nor key-redacted).
Request: pass `detail` through `hostMessage` there as well so both routes share one bound.

## Loop tests to change

`provider/messages_test.go` cases `400`, `unknown type` and `not json` currently assert the absence of the
message (`SECRET_BODY_TEXT`, e.g. "Anthropic refused HTTP 400; no route or model fallback"). They must assert
the bounded sanitised message instead (one line, at most 300 bytes, the key replaced by `[redacted]`). Add a fake
provider test that a 400 refusal shows the provider's message (`Anthropic said: …`) and contains no secret
(the saved key) and no request payload.

## Then in Kogen

Run `packaging/sync-kogen-loop.sh` to vendor the new loop and write a new `cli/loop-pin.json`.
