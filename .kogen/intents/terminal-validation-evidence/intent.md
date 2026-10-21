# Explain rejected terminal responses

Slug: terminal-validation-evidence
Model: .kogen/intents/terminal-validation-evidence/model.qnt invariants=ValidationUnchanged,HonestEvidence seed=17 samples=100 steps=12
Acceptance:
- .kogen/intents/terminal-validation-evidence/acceptance.feature
- features/steps/terminal_validation_evidence_steps.js

Extend the existing safe invalid-response detail, not validation acceptance, with bounded local structural evidence. The first real Studio Shape on signed 7af8400faebe758c09e11d7293e0728247df5420 rejected two logical-response attempts (7795 ms and 7709 ms), exited 4 after 20.581 seconds and wrote no Intent/helper; usage was unknown. Those preserved failures lack terminal/item structure. A separate native 3ef retry's five successful provider calls do not establish which 7af predicate rejected the response. Do not infer or claim a live cause. Do not inspect concurrently active Studio source, requests or provider payloads, or make sharedDB CLI calls while the coordinator's metadata hold remains.

Implement primarily in lib/kogen/chatgpt.ex, with scoped tests and maintained GPT-7/GPT-8 documentation/spec alignment. No application/example source edits, global changes, release, push, hook/signing bypass, new diagnostic service, model/cap/configuration/timeout knob or configured-check edits. .formatter.exs, mix.exs and .kogen/project.yaml remain unchanged. Native exact approval, Build, verification, independent review and signed commit remain the workflow; this Intent does not approve itself. Root retains publication, installed qualification and defaults; global remains 3ef until full response safety/compatibility qualification. Do not run real provider work or tools to manufacture diagnosis. A coordinator may later use the diagnostic private prefix for one legitimate native core operation.

## Decisions
- Preserve rejection, retry, failure/exit, cancellation, caller authority and unknown-usage rules; add only nonsecret local validation evidence. (source: request)
- Retain original failed attempts; distinguish documentation-derived fixtures from live observations and do not label local predicates as provider codes. (source: request)
- Prefer extending existing safe invalid-response failure detail/evidence over a subsystem or setting. (source: request)

### Detail contract

For the terminal-invalid branch currently returning `the completed response has invalid or unfinished output`, retain that exact leading text and append `; validation=` followed by one compact JSON object. The normal final exception retains `provider/invalid_response: ChatGPT sent a response Kogen cannot read: ` and exit 4; single_attempt retains its existing shorter prefix. Preserve other failure paths and precedence, including non-JSON events, failed/incomplete/error events and cut streams. Do not repurpose provider_failure.code or invent a provider code. Appending to detail naturally carries evidence through existing per-transport ShapeEvidence failed records, rendered errors and existing callers without a second log subsystem.

The JSON has exactly `reasons` (a deduplicated, fixed-category array) and `facts` (a fixed-key object). Categories describe facts the validator actually evaluates, not suspected upstream causes. Preserve sticky invalidation facts across terminal output replacement; distinguish the effective final output from prior streamed observations. Report all applicable categories below, sorted lexicographically; do not report a category for output that was legitimately replaced and no longer fails validation:

- `item_event_shape`: an output_item.added/done frame failed its existing index/item envelope guard.
- `terminal_envelope`: response.completed lacked a response object.
- `response_status`: completed response status fails the current nil/completed check.
- `response_error`: completed response has nonnil error (only presence, never contents).
- `usage_shape`: usage fails the current validation.
- `terminal_output_shape`: present response.output is not a list.
- `terminal_index_coverage`: terminal output fails to cover previously observed done/pending indexes.
- `empty_output`: effective output is empty.
- `noncontiguous_indexes`: effective indexes fail the current contiguity comparison.
- `pending_items`: effective pending set is nonempty.
- `item_status`: an effective item fails the current nil/completed status check.
- `item_shape`: an effective item fails current valid_item? validation (including arguments not decoding to an object).

`facts` has exactly these fields: `event_kind` (the fixed string `response.completed`), `done` (Boolean), `terminal_response_present` (Boolean), `terminal_output_present` (Boolean), `terminal_output_replaced` (Boolean), `item_count`, `pending_count`, `observed_index_count` (counts saturated at 1024), `counts_capped` (Boolean, true if any of those counts exceeded 1024), `indexes_contiguous` (Boolean), `item_types`, `item_statuses`, `arguments_object` (deduplicated sorted aggregate arrays). `observed_index_count` is the union of streamed done/pending indexes immediately before terminal replacement, or at completion if there was no replacement. Aggregates describe effective items only and contain no per-item/index lists. `item_types` allows only function_call, message, reasoning, other, unknown; `item_statuses` allows only completed, in_progress, incomplete, failed, other, unknown; unknown represents absent/null/nonstring values. `arguments_object` allows only yes, no and unknown: for effective function calls, yes means string arguments decoded to a JSON object, no means string arguments decoded otherwise or failed decoding, unknown means missing/nonstring arguments. Non-function items contribute no arguments category. Empty aggregates are allowed. These fixed arrays and capped counts bound encoded metadata independently of provider payload size and item count; the full validation JSON must be at most 2048 UTF-8 bytes. Do not truncate raw payload into that limit.

Never include raw arguments, messages, bodies, text/refusal content, tool names, call IDs, credentials, response/request/item IDs, arbitrary provider strings, payload hashes or traces. Unknown provider type/status strings map to fixed other/unknown categories, never copied. Only record safe diagnostic structure, not diagnostic guesses. Preserve existing known/unknown usage accounting: rejected completions remain unknown even if they contain valid usage. Evidence for every actual transport attempt survives a successful retry as failed/unknown, in order. No additional request, tool execution or authority is granted by diagnostics.

### Compatibility boundary

7af already accepts the basic official output_item.done and response.completed examples; no documented mismatch is established. Official documentation fetched 21 October: https://developers.openai.com/api/reference/resources/responses/streaming-events and https://developers.openai.com/api/docs/guides/function-calling#streaming . Documented added/argument delta/arguments.done/item.done streams and completed Response output with JSON-object argument strings must continue passing. The external adjacent official-event-examples.json is documentation-derived, not a live capture; it is not required as a hidden executable fixture. Acceptance constructs explicit documentation-shaped local fixtures. Do not relax unknown-item, unfinished-call, argument, status, pending/index, usage or envelope checks based on guessed Studio causes. Only a specific incompatibility proven from supported documentation/in-repository provider evidence may justify a minimal cohesive correction and reproducing regression; none was found during Shape.

## Tests
- Distinguish actual terminal rejection predicates with bounded fixed metadata: add focused result tests through ChatGPT.respond/5 using the existing real-HTTP fake, including sticky invalidation, pending/index facts and replacement semantics (regression)
- Preserve valid documented complete responses and unknown failure usage across one invalid retry: the acceptance driver sends documented-shaped function/message streams and a terminal replacement, then an invalid completion followed by success; checks exact items, usage and ordered per-attempt evidence (integration)
- Preserve invalid response privacy and native authority: installed `kogen intent shape diagnostic-next <external-request-file>` against two adversarial local completions must exit 4, retain both differentiated failed records with null usage, emit safe detail, execute no tools, write no Intent/helper, and preserve HEAD/index/approval (scenario)
- Preserve absolute 1,800,000 ms budget, refresh/backoff, single-attempt, open-stream cancellation and signal behavior: keep test/integration/provider_wait_test.exs, provider_diagnostics_test.exs and provider-wait-boundary acceptance coverage, plus existing GPT-7/GPT-8/GPT-10 scenarios; do not add another timeout gate or duplicate source critic (existing)
- Keep maintained specifications truthful: update spec/prose/08-chatgpt.md and corresponding spec/features/08-chatgpt.feature with its step vocabulary/real harness as needed, distinguishing local validation evidence from provider_failure and documentation fixtures from live evidence (integration)

## Feasibility
- Existing FakeProvider serves terminal completion over real HTTP to ChatGPT.respond/5; an empty completion produces the current generic provider/invalid_response. (probe 1: exit 0, 1.1 s)
- The small Quint model typechecks and preserves ValidationUnchanged and HonestEvidence with TypeScript simulation, seed 17, 100 samples, 12 steps. (probe 2: exit 0, 0.7 s)
- Existing installed Helpers fixture can run native Shape with an external request and two invalid completions: exit 4, generic invalid-response prefix, shape/provider_failed recovery guidance and events.ndjson present. No live provider was used. (probe 3: exit 0, 30.4 s)
