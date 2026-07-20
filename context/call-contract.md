# Call Contract — Claude/Pi Envelope

The structured JSON envelope every `codegen-call`/loop role invocation returns, and where the two
harness builders diverge. Producers: `harnesses/claude/call-dispatch.sh`, `harnesses/pi/call-dispatch.sh`
(8 builders total — both harnesses × multiple exit paths per harness: normal completion, schema-invalid,
early-exit variants).

## Envelope Shape (top-level, 21 fields across 2 nesting levels)

```json
{
  "result": { "status": "...", "value": ..., "reason": null|"...", "retry_meta": null|{...} },
  "usage": {
    "input_tokens": 0, "output_tokens": 0,
    "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0,
    "cost_usd": 0, "latency_ms": 0, "model": "...", "num_turns": 0,
    "duration_ms": null|0, "duration_api_ms": null|0, "ttft_ms": null|0,
    "permission_denials": null|0, "stop_reason": null|"..."
  },
  "error": null,
  "harness": "claude_code" | "pi",
  "session_id": null|"...",
  "metrics": {...}   // optional, present only when a JSON schema was supplied
}
```

**Model-vs-local split + hook-denial + cache signals** (`duration_ms`, `duration_api_ms`, `ttft_ms`,
`permission_denials`, `stop_reason`) — lifted from the `result` event on Claude's success path (see
pitch `build-cycle-accounts-for-its-own-time` Move 2); absent on the 3 abnormal Claude exit paths and on
ALL of pi's builders (pi's `agent_end` carries no equivalent fields). **Absent → JSON `null`, never a
fabricated `0`** — a `0` would read as "instant"/"free"/"no denials", masking the exact defect this field
exists to surface. `usage.num_turns` and `usage.total_cost_usd`-derived `cost_usd` follow the same
null-preserving contract on both harnesses (previously `// 1` / `// 0` masking-default sentinels).

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

At the queue-drain layer, a `transient?/1`-classified failure no longer consumes a `max_retries` slot
directly — it routes to an OUTAGE PAUSE (probe/hold/resume-same-slug) before `retry_eligible?/5` is ever
consulted, distinct from the deterministic-failure breaker path. See `context/loop-queue-drain.md` §
Outage Pause.

Both call-dispatch legs (`harnesses/claude/call-dispatch.sh`, `harnesses/pi/call-dispatch.sh`) also carry
a THIRD watchdog trigger, `CODEGEN_CALL_STREAM_IDLE_SECS` (default 300s), alongside the pre-existing
900s `CODEGEN_CALL_IDLE_CAP_SECS` backstop: it fires only when BOTH no output growth AND no live tool
subprocess (`pgrep -P $CHILD_PID` empty) hold for the window — the child-presence guard is what makes a
short cap safe against a role legitimately silent for minutes while a `make test`/`mix test` bash tool
runs. The default was raised from 60s to 300s after observed false kills of planner-phoenix (~10M
cache_read_tokens) whose server-side first-token latency legitimately exceeds 60s with no tool
subprocess running — a slow turn is not a dead stream. Both legs read this var identically;
`harnesses/shared/call-dispatch-parity_test.sh` enforces the cross-leg read-set stays in sync.

Both legs also read `CODEGEN_CALL_POLL_SECS` (default 5s) as the watchdog loop's own sampling cadence —
the `sleep` interval inside `while kill -0 "$CHILD_PID"` that governs how often all three triggers above
are checked. Production is unaffected (default stays 5, unset in every real build); the three watchdog
test files override it to `0.5` so killing test cases resolve in ~2s of poll latency instead of ~10s,
without changing which trigger fires or the threshold it fires at.

## Consumers

- `OrchestrationLoop` — reads `result.status`, `usage.cost_usd` (accumulated for the per-cycle budget
  cap), `session_id` (warm-resume).
- `LoopQueueDrain` — reads `usage.cost_usd` for the queue-wide spend ceiling.
- Bench/telemetry tooling — reads the full `usage` block.

## Reading the Envelope: Stdout Only, Stderr Captured Separately

The envelope is decoded from `codegen-call`'s **stdout alone** — never a merged stdout+stderr stream.
Both reader sites (`OrchestrationLoop.default_codegen_call/12` via the private `run_call_split/4` +
`decode_envelope!/3` helpers, and `Fixtures.run_codegen_call/3`) invoke `codegen-call` through a
`sh -c 'exec "$@" 2>"$CG_ERR"'` wrapper: `exec` replaces the shell in place (no extra process layer, no
altered pgid/kill semantics), stdout stays clean for the JSON parse, and stderr is redirected to a temp
file that is read back and re-emitted to the caller's own stderr afterward — so it still reaches the
drain's `_build.log` (a stdout+stderr Port capture), just at call completion rather than streaming live.

Why this matters: a writer emitting a diagnostic line to stderr (e.g. `call-dispatch.sh`'s watchdog
grace-kill notice, printed immediately before the terminal envelope on a `stderr_to_stdout: true` exit-0
path) corrupts a merged-stream JSON parse at byte 0 — `Jason.decode!` raises
`unexpected byte at position 0` naming the diagnostic line's first byte, not the actual defect. Splitting
the streams at the reader removes the corruption; a still-malformed stdout on a zero exit raises with the
received text quoted (first ~200 bytes of stdout + stderr tail) instead of a bare byte offset.

## Pi's Native Usage Shape (per-message, not top-level)

Pi's `agent_end` event carries **no top-level `usage` object and no `{"type":"usage"}` event** — the
two shapes `call-dispatch.sh` previously read, which is why every pi call reported `input_tokens: 0` /
`cost_usd: 0.0` forever. Pi reports usage **per assistant message**, in its own field vocabulary:

```json
{
  "input": 420,
  "output": 5,
  "cacheRead": 0,
  "cacheWrite": 0,
  "reasoning": 0,
  "totalTokens": 425,
  "cost": { "total": 0.001125 }
}
```

`harnesses/pi/call-dispatch.sh` sums these across every assistant message in `agent_end.messages` and
translates field names into the envelope's claude-shaped `usage` keys (`input`→`input_tokens`,
`cacheRead`→`cache_read_input_tokens`, `cacheWrite`→`cache_creation_input_tokens`, `cost.total`→`cost_usd`).
This ONLY fires as a fallback when `agent_end.usage.input_tokens` is `0` (i.e. always, for pi). The
intermediate jq object deliberately uses the SAME key names as the final envelope's `usage` block —
`harnesses/shared/call-dispatch-parity_test.sh` source-scans for `usage: {`-scoped key names, so a
differently-named intermediate key leaks into that scan as a phantom parity mismatch.

## Tolerant JSONL Parsing — Both Harnesses Are Spawned `2>&1`

Both `pi` and `claude` are spawned with stderr merged into the same capture stream as stdout JSONL
(cold-session warnings, model-catalog fetches, deprecation notices land inline). Plain `jq 'select(...)'`
**hard-aborts at the first non-JSON line and emits nothing** — it does not skip and continue. Every
`$TMP_OUT`/JSONL scan in both `call-dispatch.sh` scripts MUST use `jq -c -R 'fromjson? | select(...)'`
(raw-input + optional-decode) so a single stderr line does not make a fully successful call parse as
"no agent_end/result event found". Claude's script has always done this; pi's did not until this was
caught as a live defect (a stderr warning made every successful pi call misreport as failed).

Relatedly, the assistant reply text is extracted from the **last** assistant message with ALL its text
blocks newline-joined — never `head -1`'d. A `head -1` truncation silently drops any trailing sentinel
line (e.g. the loop's required `REVIEW_VERDICT: APPROVED` marker) from a correct multi-line reply.

## Zero-Consumer Fields (documented, not dead — kept for forward compat / debugging)

`usage.model` is captured but has no current programmatic reader — visible only via raw JSON inspection
or bench artifact dumps. `usage.latency_ms` previously had no reader; `OrchestrationLoop.accumulate_telemetry/2`
and `write_cycle_summary/6` now both read it (see `context/loop.md` § Timing/Metrics Telemetry) — retired
from this list.

## Trigger Keywords

call envelope, codegen-call contract, result.status, retry_meta, session_id null, harness asymmetry, transient error, LoopQueue.transient?, call-dispatch.sh, usage block, cache_read_input_tokens, metrics field, ajv schema validation
