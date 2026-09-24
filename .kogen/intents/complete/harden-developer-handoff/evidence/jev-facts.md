# Jev facts gathered during Shaping (23 September 2026)

A read-only worker (`kogen-worker`, claude-sonnet-5) gathered these facts. It
read the retained audit scripts and results under
`.kogen/runtime/shaping-followups/test-reliability-audit/` and fetched the
public docs without authentication. The worker never read the API key and made
no Jev API call. Separately, the root checked only that the Keychain item
`ai.typesafe.api` exists, without reading its value.

## API (docs.typesafe.ai/api.md; jev_focused_runner.py:44-52)

- Request: `POST https://api.typesafe.ai/v1/systemone` with body
  `{model, state, questions: {<id>: {type: choice|noul|score, instructions, criteria}}}`.
  The header is `Authorization: Bearer <key>`.
- Response: `{model, answers: {<id>: {type, choice, confidence, probabilities}}, usage: {input_tokens, output_tokens}}`.
- **There is no batching field.** Many questions share one `state` in a single
  request, and Jev evaluates all of them against that state.
- Documented errors are 401, 422, 429 and 529. The audit observed
  **undocumented HTTP 400s** on oversized payloads (36 of 70 exhaustive calls,
  at roughly 151–425 KB), and chunked retries succeeded.

## Limits and pricing (docs.typesafe.ai/models.md, snapshot 2026-09-23, "may change without notice")

- **Context: 64k tokens per request in total, and 32k tokens for `state` plus the single longest question.**
- Rate limits: 250k tokens per second, 1,200 requests per minute.
- $42 per billion input tokens; output is free. Input is text only.

## Data handling (docs.typesafe.ai/legal.md)

- "Jev is not trained on customer requests or responses."
- Zero data retention is available **for enterprise customers only**, by
  contacting privacy@typesafe.ai. Otherwise the standard DPA and privacy policy
  apply.

## Prior use in this repository

- The focused audit sent 10 packets of about 14–17k input tokens each, 140
  questions in total. **100 of 140 answers (71%) were `insufficient_evidence`.**
  The stated cause was missing evidence in `state`. One calibration run was
  invalid because a generic shared `state` contaminated answers across
  questions.
- Latency was about 2 s per 17k-token packet. The largest successful call had
  51k input tokens.
- The scripts had no retries. Timeouts ranged from 60 to 180 s.
- The docs list known weak points ("jaggedness") that matter here: literal
  reading, indirection, large state full of irrelevant detail, and structural
  invariants.

## Consequences for shaping

- A request for "the whole handoff in one call" does not fit. Each scenario's
  evidence includes its `then`/`wrong_result`, diff hunks, whole declared test
  files and receipts, which quickly exceeds the 32k-token state limit. A
  deterministic set of several requests, each within the limit, is required.
  Jev cannot batch within a single call.
- Kogen has no HTTP client today (mix.exs has only jason, yaml_elixir, boundary
  and credo). Adding one is part of any Jev Intent.
