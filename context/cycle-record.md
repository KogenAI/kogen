# Cycle Record — `codegen-log`, Gate-Pending Artifacts, Gate Verdict Truth Table

The durable record of one build cycle: the append-only JSONL cycle log, the ephemeral gate-pending
artifacts the loop reads/writes between roles, and the deterministic verdict-derivation table that
turns a raw gate run into `clear`/`failed`/`inconclusive`.

Full `codegen-log` CLI contract (subcommands, resolution precedence, substance filter, event schema) is
owned by `shared/rules/_core/session-log.md` — this file does not re-teach the CLI, it documents the
artifacts and the verdict table that session-log.md references but doesn't itself own.

## `ev` Event Kinds (11, not 6 — corrects a stale prior count)

`init`, `role`, `learned`, `no_learning`, `died`, `gate`, `plan`, `plan_gate`, `files_to_touch`,
`files_modified`, `exit`. Verified via `codegen-log --kinds`.

## `codegen/gate-pending/` Artifacts

- `gate-result.json` — one gate attempt's structured result. Written by `write_gate_result` (in
  `harnesses/claude/hooks/lib/gate-result.sh`, sourced by the loop's gate step). Overwritten each
  attempt (not append-only, unlike the cycle log).
- `cycle-state.json` — durable checkpoint for warm-resume (`GATED`/`REVIEWED`/`CURATED`/`COMMITTED`).
  Schema: `{ "state": "GATED|REVIEWED|CURATED|COMMITTED", "step_log": "path/to/cycle.log", "session_id": "cycle_id", "verdict": "clear|failed|inconclusive|\"\"", "slug": "pitch-name", "updated_at": "ISO-8601" }`. Fields `step_log`, `session_id`, and `slug` may be empty strings. The `slug` field is stamped by the loop during cycle execution and read by the resume guard to verify the checkpoint belongs to THIS pitch and not a foreign one (see `context/loop.md` § Warm-Resume).
- `.active` — sentinel pointing at the currently-resolved cycle log path (written by `codegen-log init`).

## Gate Verdict Truth Table (`_derive_verdict`, fully deterministic)

| Input condition                                            | Verdict      | Marker                 |
| ---------------------------------------------------------- | ------------ | ---------------------- |
| `runner_found=false`                                       | failed       | FAILED ❌              |
| `exit_code="timeout"`                                      | inconclusive | INCONCLUSIVE ⚠️        |
| `exit_code` ∈ {126,127}                                    | failed       | FAILED ❌              |
| `exit≠0`, classification ∈ {seed-missing, pool-exhaustion} | inconclusive | INCONCLUSIVE ⚠️        |
| `exit≠0` (other)                                           | failed       | FAILED ❌              |
| `exit=0`, `execution_evidence < expected_segments`         | failed       | FAILED ❌ (no-op gate) |
| `exit=0`, `render_verdict=FAIL:*`                          | failed       | FAILED ❌              |
| `exit=0`, `render_verdict=INCONCLUSIVE:*`                  | inconclusive | INCONCLUSIVE ⚠️        |
| `exit=0`, evidence ok, render ∈ {PASS, ""}                 | clear        | ALL CLEAR ✅           |

`"inconclusive"` fails CLOSED at the loop's consumption point (`LoopGate` treats it as `:failed` for
retry/escalation purposes) — never silently treated as passing.

## `write_gate_result` Fields (full schema)

`gate`, `mode`, `base_sha`, `diff_files_count`, `runner_found`, `exit`, `execution_evidence`,
`expected_segments`, `render_verdict`, `verdict`, `verdict_marker`, `classification`, `started`, `ended`,
`duration_s`, `session_id`, `log`, `witness`, `graded_tree_sha`.

`graded_tree_sha` binds the verdict to the exact working-tree CONTENT it graded — `base_sha` alone only
pins HEAD, not content (a post-gate revert leaves `base_sha` unchanged but changes tree content).

`duration_s` is derived from `started`/`ended` (via `jq`'s `fromdateiso8601`, portable across
macOS/Linux) — `null` when either timestamp is unparseable/empty, never a fabricated `0` (see pitch
`build-cycle-accounts-for-its-own-time`). `session_id` is now populated by the loop's `gate_opts/2` with
the acting developer role (`dev_role_from_ctx/1` fallback) rather than left at `LoopGate.run_gate/2`'s
own anonymous `""` default — see `context/loop.md` § Timing/Metrics Telemetry.

## Witness Extraction

`extract_witness <log_path>` — best-effort, fall-open-empty (never errors; missing witness never breaks
the gate). ExUnit-aware: finds the first `  N) test ...` headline block, prefers the stacktrace's first
frame over the raw definition line (definition line misleads on setup-raise and doctests). Falls back to
a generic `file:line` grep for credo/dialyzer-style output. See `shared/rules/_core` § Witness
Discipline for the cross-role contract this feeds.

## `gate-verdicts.jsonl` — Producer Confirmed

`codegen/logging/gate-verdicts.jsonl` (a prior open question — "no producer found") IS written: inside
`write_gate_result`, guarded by `[ -f "$project_dir/shared/enforcement/registry.yaml" ]` (only fires in
the codegen repo itself, not downstream apps) — appends `jq -c '.' "$result_file"` to the history file,
fail-open (`|| true`, never blocks a gate on observability). This is a durable, append-only, codegen-only
verdict history — distinct from the per-cycle `gate-result.json` which gets overwritten each attempt.

## Enforcement Points (8)

Cross-reference `shared/rules/_core/session-log.md` § Enforcement for the full list
(`session-log-writer-only`, `role-retrospective-before-stop`, plus this file's gate-result consumers).

## Trigger Keywords

codegen-log, cycle log, gate-pending, gate-result.json, cycle-state.json, write_gate_result, derive_verdict, verdict truth table, extract_witness, witness discipline, gate-verdicts.jsonl, graded_tree_sha, ev kinds, .active sentinel
