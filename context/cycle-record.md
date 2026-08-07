# Cycle Record — `codegen-log`, Gate-Pending Artifacts, Gate Verdict Truth Table

The durable record of one build cycle: the append-only JSONL cycle log, the ephemeral gate-pending
artifacts the loop reads/writes between roles, and the deterministic verdict-derivation table that
turns a raw gate run into `clear`/`failed`/`inconclusive`.

Full `codegen-log` CLI contract (subcommands, resolution precedence, substance filter, event schema) is
owned by `shared/rules/_core/session-log.md` — this file does not re-teach the CLI, it documents the
artifacts and the verdict table that session-log.md references but doesn't itself own.

## MCP Tool Façade (`harnesses/claude/mcp-server/`)

Agents SHOULD prefer the `mcp__codegen__*` MCP tool over hand-composed `codegen-log` bash when granted
it — the CLI stays fully working for scripts/hooks/humans and every other caller in this file. The
server is a thin stdio façade: each tool handler execs `codegen-log` via array-argv `execFileSync` with
the body on stdin (never a shell string), so it writes/reads the exact same JSONL log and
`gate-result.json` this file documents — no new artifact, no new schema.

**Role-baking**: writer tools are GENERATED per concrete role (`log_section_<role>`/`log_append_<role>`,
e.g. `mcp__codegen__log_section_developer_phoenix_backend`) — role is hardcoded server-side, never a
caller argument. This closes the `unsupported role`/`no role (AGENT_TYPE unset)` failure class that
hand-composed bash could hit: a role can only call the tool it was granted, and that grant IS its role.
Role-less readers: `gate_status` (verdict/exit/witness from `gate-result.json`) and `log_read` (view:
`manifest`|`retro`|`full` — the loop's `ev:files_to_touch` events, `ev:learned` only, or every event).

**Grant site**: each of the 7 concrete roles' `shared/subagents/**/*.md.j2` `tools:` frontmatter line —
verified the actual offered-tool gate under `--agent` (`--allowedTools`/`--tools` alone does NOT expose
an MCP tool there). Dispatch wiring: `call-dispatch.sh` (Claude) adds `--mcp-config <resolved config>`
beside the existing `--strict-mcp-config`, generated on the fly per-machine and omitted when
`mcp-server/dist/index.js` hasn't been built — see `context/harnesses.md` for the dispatch-side detail.
`dispatch.sh` (execs `mix codegen.loop`) carries no MCP wiring; it has no `claude` argv to edit.

## `ev` Event Kinds (11)

`committed`, `died`, `exit`, `files_modified`, `files_to_touch`, `gate`, `init`, `learned`,
`no_learning`, `role`, `waiver`. Verified via `codegen-log --kinds`. There is no `plan` or
`plan_gate` kind — the pitch body plus the loop's `## Declared Scope` block replace the plan
document, and the gate is declared per-project in `<project>/.claude/gate-config.sh`. `waiver`
(`role`, `hook`, `slug`) is written by `harnesses/claude/hooks/_waiver.sh` (+ `.ts` twin) at the
moment a `waivable: true` registry entry is granted a waiver for a promoted pitch's `waives:`
declaration — see `shared/rules/_core/session-log.md` § A guard is waived only where a pitch
declared it.

## `codegen/gate-pending/` Artifacts

- `gate-result.json` — one gate attempt's structured result. Written by `write_gate_result` (in
  `harnesses/claude/hooks/lib/gate-result.sh`, sourced by the loop's gate step). Overwritten each
  attempt (not append-only, unlike the cycle log).
- `cycle-state.json` — durable checkpoint for warm-resume (`GATED`/`REVIEWED`/`CURATED`/`COMMITTED`).
  Schema: `{ "state": "GATED|REVIEWED|CURATED|COMMITTED", "step_log": "path/to/cycle.log", "session_id": "cycle_id", "verdict": "clear|failed|inconclusive|\"\"", "slug": "pitch-name", "updated_at": "ISO-8601" }`. Fields `step_log`, `session_id`, and `slug` may be empty strings. The `slug` field is stamped by the loop during cycle execution and read by the resume guard to verify the checkpoint belongs to THIS pitch and not a foreign one (see `context/loop.md` § Warm-Resume).
- `.active` — sentinel pointing at the currently-resolved cycle log path (written by `codegen-log init`).
- `recoveries/<slug>/<transaction-id>.json` — per-transaction recovery dossier (`schema_version: 1`,
  stages `parking`→`parked`→`history_written`→`ready`→`materialized`/`superseded`→`completed`; see
  `context/loop.md` § Interrupted-Cycle Recovery). Same gitignore/machine-local/never-transported contract
  as every other `gate-pending/` artifact below — never git-tracked, never carried cross-box by
  `codegen-drain assign` (which refuses a cross-node transfer of any slug with an active dossier).

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

For a non-clear result, `write_gate_result` also falls back to
`extract_witness "$log"` when a caller omits the optional witness argument.
This keeps direct/legacy callers actionable without inspecting logs for clear
results, where a warning location would be misleading.

## Witness Extraction

`extract_witness <log_path>` — best-effort, fall-open-empty (never errors; missing witness never breaks
the gate). ExUnit-aware: finds the first `  N) test ...` headline block, prefers the stacktrace's first
frame over the raw definition line (definition line misleads on setup-raise and doctests). Falls back to
a generic `file:line` grep for credo/dialyzer-style output. See `shared/rules/_core` § Witness
Discipline for the cross-role contract this feeds.

## Whole-Pitch Completeness — Pre-Commit Deterministic Floor

Distinct from the gate: `CodegenTestHarness.BornDeadDetector.check/2` scans the cycle diff for defer
markers and born-dead new entities (no live caller, no registration) BEFORE the commit is trusted.
Wired into both `OrchestrationLoop.assert_work_produced!/2` (solo, raises) and `LoopQueueDrain`'s
`:born_dead_fn` seam (drain, routes to false-0 park-and-continue) — see `context/loop.md` § Whole-
Pitch Completeness Backstop for the full contract.

## `gate-verdicts.jsonl` — Producer Confirmed

`codegen/logging/gate-verdicts.jsonl` (a prior open question — "no producer found") IS written: inside
`write_gate_result`, guarded by `[ -f "$project_dir/shared/enforcement/registry.yaml" ]` (only fires in
the codegen repo itself, not downstream apps) — appends `jq -c '.' "$result_file"` to the history file,
fail-open (`|| true`, never blocks a gate on observability). This is a durable, append-only, codegen-only
verdict history — distinct from the per-cycle `gate-result.json` which gets overwritten each attempt.

## No Git-Tracked Logs

`codegen/logging/*_cycle.jsonl` is gitignored (`.gitignore` `/codegen/` pattern) and this is a
deliberate, permanent boundary — cycle logs are machine-local working artifacts and MUST NEVER be
carried through git, on this or any other machine. `codegen-log` has no publish/sync/export
subcommand and never will; a prior mechanism (`codegen-log corpus publish`/`corpus sync`, an orphan
`refs/heads/corpus` branch) existed and was REMOVED by operator decision — carrying logs across boxes
via a git ref/branch/note/stash is explicitly NOT a goal this codebase pursues.

- **Never re-add a cross-box log transport.** No orphan branch, no `git notes`, no `git stash`, no
  wrapper script/Mix task that hashes, commits, or pushes a cycle log anywhere. A cycle log surviving
  one machine is not a requirement — logs are ephemeral, per-box, and disposable.
- **Enforcement lives at the rule layer**, not a hook: `shared/rules/_core/session-log.md` § Ownership
  states the prohibition explicitly. Reviewer flags any reintroduction of a corpus-branch-shaped
  mechanism as a design regression, not a style nit.
- **Rationale**: operator determined the mechanism contradicted the "cycle logs stay local" contract —
  removal is the approved, final disposition; no replacement transport is planned or wanted.

## Audit Session Logs

Markdown audit/session records under `codegen/logging/` are machine-local evidence artifacts, not
cycle-record schema sources. An audit-only record does not change the JSONL event schema, gate
artifacts, or verdict contract; durable findings belong in the owning domain context only when the
audited product behavior changes.

## Enforcement Points (8)

Cross-reference `shared/rules/_core/session-log.md` § Enforcement for the full list
(`session-log-writer-only`, `role-retrospective-before-stop`, plus this file's gate-result consumers).

## Trigger Keywords

codegen-log, cycle log, gate-pending, gate-result.json, cycle-state.json, write_gate_result, derive_verdict, verdict truth table, extract_witness, witness discipline, gate-verdicts.jsonl, graded_tree_sha, ev kinds, .active sentinel, no git-tracked logs, no cross-box log transport, recovery dossier, dossier stages, machine-local gitignored ephemeral artifact, recoveries/<slug>/<txid>.json, schema_version, transaction identity
