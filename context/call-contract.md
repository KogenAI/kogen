# Call Contract — Claude/Pi Envelope

The structured JSON envelope every `codegen-call`/loop role invocation returns, and where the two
harness builders diverge. Producers: `harnesses/claude/call-dispatch.sh`, `harnesses/pi/call-dispatch.sh`
(8 builders total — both harnesses × multiple exit paths per harness: normal completion, schema-invalid,
early-exit variants).

## Envelope Shape (top-level, 16 fields across 2 nesting levels)

```json
{
  "result": { "status": "...", "value": ..., "reason": null|"...", "retry_meta": null|{...} },
  "usage": {
    "input_tokens": 0, "output_tokens": 0,
    "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0,
    "cost_usd": 0, "latency_ms": 0, "model": "...", "num_turns": 0
  },
  "error": null,
  "harness": "claude_code" | "pi",
  "session_id": null|"...",
  "metrics": {...}   // optional, present only when a JSON schema was supplied
}
```

## Claude vs Pi Asymmetries (17 total, swept; a sample — not exhaustive)

- **`session_id`**: 3 of Claude's 4 envelope builders hardcode `null` even on success (only the
  post-completion success path emits the real Claude session id). Pi's 4 builders ALL emit a real
  session id. This is a real gap on Claude's warm-resume path — a builder emitting `null` where a real
  id was available loses resumability. (Corrects a prior doc that had this backwards.)
- **`retry_meta`**: both harnesses hardcode `null` at all early-exit sites (3 sites each) — retry
  metadata is only ever populated on the normal completion path, never on schema-invalid/early-exit
  paths. This is symmetric across harnesses (a previously-suspected divergence, refuted by direct grep).
- **`metrics`**: present ONLY when a JSON schema was supplied to the call AND the schema validator
  (`ajv`) resolved; absent → the field is omitted entirely (not `null`) via the trailing
  `+ (if $metrics == null then {} else {metrics: $metrics} end)` jq merge.

## Transient-Error Taxonomy

Classifies a call failure as transient (retry-eligible) vs deterministic (no retry). Consumed at 3
mirror sites: `LoopQueue.transient?/1` (queue drain retry gate), the single-cycle loop's retry-budget
check (`context/loop.md`), and the call-dispatch scripts' own early-exit branches. Keeping these three
in sync is a live parity concern — `LoopQueue.transient?/1` is unit-tested directly; the dispatch-script
copies are not cross-checked by an automated parity test.

## Consumers

- `OrchestrationLoop` — reads `result.status`, `usage.cost_usd` (accumulated for the per-cycle budget
  cap), `session_id` (warm-resume).
- `LoopQueueDrain` — reads `usage.cost_usd` for the queue-wide spend ceiling.
- Bench/telemetry tooling — reads the full `usage` block.

## Zero-Consumer Fields (documented, not dead — kept for forward compat / debugging)

`usage.latency_ms` and `usage.model` are captured but have no current programmatic reader — visible only
via raw JSON inspection or bench artifact dumps.

## Trigger Keywords

call envelope, codegen-call contract, result.status, retry_meta, session_id null, harness asymmetry, transient error, LoopQueue.transient?, call-dispatch.sh, usage block, cache_read_input_tokens, metrics field, ajv schema validation
