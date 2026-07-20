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
`manifest`|`retro`|`full` — planner's typed events, `ev:learned` only, or every event).

**Grant site**: each of the 9 concrete roles' `shared/subagents/**/*.md.j2` `tools:` frontmatter line —
verified the actual offered-tool gate under `--agent` (`--allowedTools`/`--tools` alone does NOT expose
an MCP tool there). Dispatch wiring: `call-dispatch.sh` (Claude) adds `--mcp-config <resolved config>`
beside the existing `--strict-mcp-config`, generated on the fly per-machine and omitted when
`mcp-server/dist/index.js` hasn't been built — see `context/harnesses.md` for the dispatch-side detail.
`dispatch.sh` (execs `mix codegen.loop`) carries no MCP wiring; it has no `claude` argv to edit.

## `ev` Event Kinds (13, not 6 — corrects a stale prior count)

`init`, `role`, `learned`, `no_learning`, `died`, `gate`, `plan`, `plan_gate`, `files_to_touch`,
`files_modified`, `exit`, `committed`, `waiver`. Verified via `codegen-log --kinds`. `waiver`
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

## Corpus Branch

`codegen/logging/*_cycle.jsonl` is gitignored (`.gitignore` `/codegen/` pattern) — the learning corpus
(every `ev:learned` a cycle ever wrote) is otherwise per-box, invisible to a clone or a second machine.
`refs/heads/corpus` is an orphan git branch carrying every cycle log verbatim, written by `codegen-log
corpus publish` and read by `codegen-log corpus sync`.

- **Codegen-only.** Both verbs no-op silently (exit 0, write/materialize nothing) unless
  `shared/enforcement/registry.yaml` exists under repo root — the same sentinel `write_gate_result` uses
  to gate `gate-verdicts.jsonl` above. A downstream Phoenix/static app never grows a corpus branch.
- **`publish`** resolves the log via `CODEGEN_LOG_PATH` ONLY (never `--slug`/`.active`/mtime — a publish
  must never guess which run it belongs to; exits 2 when unset). Validates the basename against the
  canonical regex (`codegen/logging/[0-9]{8}_[0-9]{6}_[a-z0-9_-]+_cycle\.jsonl$` — the same pattern
  `registry.yaml` already carries). Never opens the repo's own git index or touches the working tree:
  `git hash-object -w`, a tree built under a TEMPORARY `GIT_INDEX_FILE`, `commit-tree` onto the fetched
  tip of `refs/heads/corpus` (no parent on first publish), `update-ref`, `push`. A non-fast-forward
  push is retried once (fetch tip, replay); a second rejection retains the commit on the local branch
  only and is logged, never raised — the next successful publish carries the backlog.
- **`sync`** fetches `refs/heads/corpus` and materializes into `codegen/logging/` any canonical-shaped
  file present on the branch but absent locally. A non-canonical branch entry (e.g. a hostile or
  malformed push) is never materialized. Materialized files have their mtime stamped from the
  filename's own `YYYYMMDD_HHMMSS` prefix, never "now" — codegen-log's own last-resort log resolver is
  newest-mtime, and a foreign log stamped at checkout time could otherwise win that fallback and
  receive a local write meant for a different run. Idempotent — an already-present file is left alone.
- **Loop wiring.** `sync` runs immediately before `codegen-log init` (cycle start); `publish` runs at
  the tail of the cycle, on the ok path, the error path, and a raise (an `after` block) — a cycle that
  failed still contributes its learnings. `ev:exit` (dispatch.sh's own record of the child process's
  wait status, written by the PARENT process after the loop has already exited) is therefore never
  present in the published copy — it is a dispatch-level fact, not a learning.
- **Fail-loud-non-blocking**, same posture as every other codegen-only observability write in this
  file: any failure (no network, non-canonical path, push rejected twice) prints to stderr and returns
  normally — never raises, never changes the cycle's own outcome or return value.
- **Never role-authored.** Both verbs are invoked by the orchestration loop itself
  (`default_corpus_sync/1` / `default_corpus_publish/1` in `orchestration_loop.ex`, seam-overridable via
  `:corpus_sync_fn` / `:corpus_publish_fn` opts) — no subagent prompt names either verb.

## Enforcement Points (8)

Cross-reference `shared/rules/_core/session-log.md` § Enforcement for the full list
(`session-log-writer-only`, `role-retrospective-before-stop`, plus this file's gate-result consumers).

## Trigger Keywords

codegen-log, cycle log, gate-pending, gate-result.json, cycle-state.json, write_gate_result, derive_verdict, verdict truth table, extract_witness, witness discipline, gate-verdicts.jsonl, graded_tree_sha, ev kinds, .active sentinel
