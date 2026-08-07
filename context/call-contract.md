# Call Contract — Envelope

The structured JSON envelope every `codegen-call`/loop role invocation returns, and where the two
harness builders diverge. Producer: `harnesses/claude/call-dispatch.sh`
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
  "harness": "claude_code",
  "session_id": null|"...",
  "metrics": {...}   // optional, present only when a JSON schema was supplied
}
```

**Model-vs-local split + hook-denial + cache signals** (`duration_ms`, `duration_api_ms`, `ttft_ms`,
`permission_denials`, `stop_reason`) — lifted from the `result` event on Claude's success path (see
pitch `build-cycle-accounts-for-its-own-time` Move 2); absent on the 3 abnormal Claude exit paths and on
every builder. **Absent → JSON `null`, never a
fabricated `0`** — a `0` would read as "instant"/"free"/"no denials", masking the exact defect this field
exists to surface. `usage.num_turns` and `usage.total_cost_usd`-derived `cost_usd` follow the same
null-preserving contract on both harnesses (previously `// 1` / `// 0` masking-default sentinels).

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

`harnesses/claude/call-dispatch.sh` also carries
a THIRD watchdog trigger, `CODEGEN_CALL_STREAM_IDLE_SECS` (default 300s), alongside the pre-existing
900s `CODEGEN_CALL_IDLE_CAP_SECS` backstop: it fires only when BOTH no output growth AND no live tool
subprocess hold for the window. The child-presence guard is
what makes a short cap safe against a role legitimately silent while a `make test`/`mix test` tool
runs. Claude ignores its always-on codegen MCP server child in this guard; that child is transport
plumbing, not tool work, and otherwise permanently disables the stream-idle trigger. The default was
raised from 60s to 300s after observed false kills of a heavy-Read role turn (~10M
cache_read_tokens) whose server-side first-token latency legitimately exceeds 60s with no tool
subprocess running — a slow turn is not a dead stream. Both legs read this var identically;

The dispatcher snapshots its own script and schema-validator entry before launching the CLI,
so an in-role edit cannot make the active Bash invocation read mixed old/new bytes. Terminal salvage kills the entire producer process group, while
every filter startup/status/write/drain failure also terminates and reaps that group before returning
non-zero. The filtered capture drops only parsed top-level `message_update` snapshots; terminal, tool,
usage, lifecycle, and non-JSON diagnostic records remain available to envelope parsing/transcripts.

Both legs also read `CODEGEN_CALL_POLL_SECS` (default 5s) as the watchdog loop's own sampling cadence —
the `sleep` interval inside `while kill -0 "$CHILD_PID"` that governs how often all three triggers above
are checked. Production is unaffected (default stays 5, unset in every real build); the three watchdog
test files override it to `0.5` so killing test cases resolve in ~2s of poll latency instead of ~10s,
without changing which trigger fires or the threshold it fires at.

When the idle or dead-stream trigger terminates Claude, its observed cause is
authoritative in the failed envelope even if Claude writes a late interrupted
`result` event while handling SIGTERM. That preserves the retryable `Stream
idle timeout` token for the loop. The separate result-present grace trigger
has no failure cause and continues to salvage the already-emitted result.

Claude loop calls run in a dedicated POSIX session/process group created by a tiny forked Perl
supervisor (portable across Darwin/Linux; Perl is already the timestamp fallback). A separate,
independently-sessioned guardian watches the dispatcher, supervisor, and the BEAM OS PID supplied by
`run_call_split/4` as `CODEGEN_CALL_OWNER_OS_PID`. Dispatcher signal/exit traps, watchdog kills,
normal return, and guardian detection of dispatcher/BEAM death all terminate the owned group with
TERM then KILL. The guardian survives even whole-dispatcher-process-group termination. Live-tool
detection scans every member of the owned Claude PGID; the configured MCP executable and its
descendant plumbing are excluded by ancestry. `CODEGEN_CALL_OWNER_OS_PID`,
`CODEGEN_CALL_GUARD_POLL_SECS`, and `CODEGEN_CALL_TERM_GRACE_SECS` are intentionally Claude-only:

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

## Tolerant JSONL Parsing — The Harness Is Spawned `2>&1`

`claude` is spawned with stderr merged into the same capture stream as stdout JSONL
(cold-session warnings, model-catalog fetches, deprecation notices land inline). Plain `jq 'select(...)'`
**hard-aborts at the first non-JSON line and emits nothing** — it does not skip and continue. Every
`$TMP_OUT`/JSONL scan in both `call-dispatch.sh` scripts MUST use `jq -c -R 'fromjson? | select(...)'`
(raw-input + optional-decode) so a single stderr line does not make a fully successful call parse as
"no agent_end/result event found". Claude's script has always done this.

Relatedly, the assistant reply text is extracted from the **last** assistant message with ALL its text
blocks newline-joined — never `head -1`'d. A `head -1` truncation silently drops any trailing sentinel
line (e.g. the loop's required `REVIEW_VERDICT: APPROVED` marker) from a correct multi-line reply.

## Zero-Consumer Fields (documented, not dead — kept for forward compat / debugging)

`usage.model` is captured but has no current programmatic reader — visible only via raw JSON inspection
or bench artifact dumps. `usage.latency_ms` previously had no reader; `OrchestrationLoop.accumulate_telemetry/2`
and `write_cycle_summary/6` now both read it (see `context/loop.md` § Timing/Metrics Telemetry) — retired
from this list.

## Trigger Keywords

call envelope, codegen-call contract, result.status, retry_meta, session_id null, harness asymmetry, transient error, LoopQueue.transient?, call-dispatch.sh, usage block, cache_read_input_tokens, metrics field, ajv schema validation, stream idle watchdog, watchdog cause, late result event, MCP server child, process group, guardian, orphan cleanup
