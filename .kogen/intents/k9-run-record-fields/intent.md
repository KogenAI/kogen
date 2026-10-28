# Record round, cache-write and read fields in runs

Slug: k9-run-record-fields
Model: not applicable — the change only adds fields to append-only run records; it has no state transitions
Acceptance:
- .kogen/intents/k9-run-record-fields/acceptance.feature
- features/steps/k9_run_record_steps.js
- features/steps/k9_build_record_driver.go
- features/steps/k9_shape_record_driver.go

Run records gain exactly six groups of fields so research can measure cache and context mechanisms. Nothing else is added: no command, flag, user-visible output, telemetry, or change to provider requests. Existing record fields and their values stay unchanged; the new fields are additions on the existing events. No record gets request content, a raw file path or file content: only hashes, byte counts, token counts and line numbers.

Where: Build and review events go to `.kogen/local/runs/<id>/log.jsonl`; Shape's go to the existing shaping events (`.kogen/local/shaping/<slug>/events.ndjson`). The Shape equivalent of the Build `request` event is its existing `provider_call` event (one per transport attempt); it gets the fields that apply to it.

1. Round number on each request event, exactly one field: `build_round` (the Build round number, from 1) on build-role requests, `review_round` (the review number, from 1) on review requests, `shape_attempt` on Shape requests. Shape attempt: the 1-based number of the shaper submission attempt the request belongs to; every request before the first refused or fed-back submission (including the request audit) is attempt 1, and the request that follows that feedback is attempt 2, and so on. The other two round fields are absent.
2. `cache_write` in the request event's `usage` object, next to `cached`: the provider-reported cache-write tokens (Anthropic `cache_creation_input_tokens`, which the provider layer already normalizes as the known usage `write`; the Responses `input_tokens_details.cache_write_tokens` maps to the same value), `null` where the provider does not report it. It appears (as null when unknown) on every request event. Shape's `provider_call` usage gets it likewise.
3. On a `tool_call` / `review_tool_call` event whose result was cut by tools.Cut (the 16384-byte display bound): `bytes_before_cut` (the uncut result size in bytes) and `bytes_delivered` (the byte size of the delivered cut text, at most 16384). Both are absent when no cut happened.
4. `request_bytes` on each request event: the byte length of the serialized request body sent to the provider (also on Shape `provider_call`).
5. On read-type tool calls (`read_file`, including reads of private review source parts), on the `tool_call` / `review_tool_call` event: `source` and `content_sha256`. `source` is `{kind: "review_source_part", part_id}` for a pinned review source part, or `{kind: "file", path_sha256, start_line, end_line, whole}` for a file: `path_sha256` is the SHA-256 hex of the path string exactly as the model supplied it, `start_line`/`end_line` the 1-based inclusive lines actually returned, `whole` true when they cover the whole file. `content_sha256` is the SHA-256 hex of the entire file bytes (or the entire part bytes) at read time, not only the returned range. Non-read tool calls have neither field.
6. A working-window reset records `input_tokens_before`, `input_tokens_after` (integers: the measured input size, in the same units the reset's preflight already uses for the ceiling check, before and after the reset; after is smaller than before) and `carried_items` (the number of input items kept in the reduced window). Build and review currently report resets only as a progress line and have no run-log event; they get a new run-log event `window_reset` with `owner` (`build` or `review`) plus these three fields (and no content). Shape's existing `working_context_reset` event gets the same three fields.

The pinned copy under `cli/third_party/kogen-loop` and `cli/loop-pin.json` must not be changed at all: they are written only by `packaging/sync-kogen-loop.sh` from a kogen-loop commit. Every field is recorded from Kogen code outside that directory, for example by measuring sizes and hashes where Kogen receives tool results and builds requests. If a field truly cannot be recorded without changing kogen-loop, the Build stops with a blocker naming the kogen-loop change needed instead of editing the copy.

## Decisions
- Exactly the six requested field groups are added, as additions on existing events; no other telemetry, command, flag or output. (source: request)
- Provider requests are unchanged; records only. (source: request)
- Records hold only hashes, byte counts, token counts and line numbers, never raw paths, content or request text. (source: request)
- Shape's request event is `provider_call`, and it carries `shape_attempt`, `request_bytes` and `usage.cache_write`; the audit request is attempt 1. (source: request)
- Build and review resets get a new `window_reset` run-log event because no reset event existed in the run log. (source: request)
- `content_sha256` hashes the entire file or part, and `path_sha256` hashes the path as the model supplied it. (source: request)
- `cli/third_party/kogen-loop` and `cli/loop-pin.json` are not edited; fields are recorded from Kogen code outside it, or the Build stops with a blocker naming the needed kogen-loop change. (source: request)

## Source comparison
- Item 1 round fields: addressed; `build_round`, `review_round`, `shape_attempt` on request events and Shape `provider_call`; acceptance scenarios 1 and 2; Shape attempt numbering is a decision of this contract.
- Item 2 `cache_write`: addressed in `usage` next to `cached`, null when unreported; acceptance uses a Responses-route fake usage with `cache_write_tokens` 20 (same normalized `write` as Anthropic `cache_creation_input_tokens`); the Anthropic mapping itself is covered by a provider unit test, not the scenario.
- Item 3 cut bytes: addressed for a 40960-byte shell result (`bytes_before_cut` 40960..42000, `bytes_delivered` <= 16384), absent otherwise.
- Item 4 `request_bytes`: addressed; compared to the body size the fake provider received within 5% (or 64 bytes).
- Item 5 read source: addressed for a ranged file read in Build, and whole and ranged file reads in review; the `review_source_part` kind is specified and covered by a unit test on the existing review part-read path, not by the scenario.
- Item 6 reset fields: addressed for the Build reset (new `window_reset` event); Shape/review/Refine-shaped resets are covered by unit tests.
- Correction (pinned copy): superseded the earlier allowance to change `cli/third_party/kogen-loop` with a prohibition on any change to it or `cli/loop-pin.json`; fields come from Kogen code outside it, with a named-blocker stop if impossible.
- Must stay: no new command/flag/output, no content in records, requests unchanged, existing fields unchanged: addressed (existing fields asserted present, privacy asserted over request, tool_call, review_tool_call and window_reset events).
- Acceptance wording `40960-ish`: addressed as the 40960..42000 range because the shell result carries framing text.
- Host safety: no process control; scenarios use temp directories only.

## Tests
- Round fields on request events (build_round, review_round, shape_attempt): acceptance scenarios 1 and 2 (scenario)
- cache_write in request usage, null when unreported: scenario 1, plus a unit test in Build code outside the pinned kogen-loop copy for the Anthropic usage mapping from `cache_creation_input_tokens` (unit)
- bytes_before_cut and bytes_delivered only on cut results: scenario 1 (scenario)
- request_bytes equals the serialized body size: scenarios 1 and 2 (scenario)
- source and content_sha256 on read calls, including `review_source_part` with part_id: scenario 1 for file reads, and an assertion added to the existing review part-read test in cli/build/review_delivery_test.go for part reads (unit)
- window_reset fields on Build and review resets: scenario 1, and a Shape window test asserting the three fields on working_context_reset (unit)
- No raw path or file content in records: scenario 1 privacy check (scenario)
- Existing record fields and behavior unchanged, and the pinned copy untouched (`TestLoopPin` passes unchanged): existing Go tests and configured checks (existing)

## Feasibility
- evidence: {"id":"k9-observer","kind":"observer","inputs":["features/steps/k9_run_record_steps.js","features/steps/k9_build_record_driver.go","features/steps/k9_shape_record_driver.go"],"observers":["features/steps/k9_run_record_steps.js"],"checks":[{"name":"good","command":"node features/steps/k9_run_record_steps.js --control good","exit":0,"output":"k9 observer good\n"},{"name":"bad","command":"node features/steps/k9_run_record_steps.js --control bad","exit":1,"output":"k9 observer rejected bad fixtures\n"}]}
- The Build driver was run against the unchanged tree in a scratch copy: exit 0, 45 requests (43 build, 2 review), 44 tool_call and 2 review_tool_call events, shell results delivered as 16384 bytes, and none of the new fields present yet, so the scenarios fail now only for the missing fields. (probe: exit 0, 16.9 s)
- Kogen's Build code builds the `provider.Request` and receives tool results and the response itself (cli/build/build.go request event), so sizes and hashes can be measured there without touching the pinned copy.
