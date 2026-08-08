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
own anonymous `""` default — see § Timing/Metrics Telemetry below.

For a non-clear result, `write_gate_result` also falls back to
`extract_witness "$log"` when a caller omits the optional witness argument.
This keeps direct/legacy callers actionable without inspecting logs for clear
results, where a warning location would be misleading.

## Timing/Metrics Telemetry

Three durable, `cycle_id`-keyed timing ledgers exist independently — `cycle-summary.jsonl` (per-role
call, `latency_ms`/`duration_ms`/`duration_api_ms`/`ttft_ms`), `preflight-timings.jsonl` (turn-0
`gate`/`roles`/`orientation` preflight steps), `gate-verdicts.jsonl` (`duration_s` per gate run) — but
nothing joined them into a total or named the residual. `Mix.Tasks.Codegen.Loop.emit_loop_telemetry/3`
(pitch `cycle-records-where-its-time-went`) closes that: the result envelope's `"timeline"` block joins
all three by `cycle_id`:

- `roles` — per-role-call duration fields, read from in-process telemetry (no file read; already
  retained by `accumulate_telemetry/3`).
- `preflight` / `gate` — this cycle's rows from the two sibling ledgers, matched on `cycle_id`.
- `wall_ms` — now minus the cycle's start, decoded from `cycle_id`'s `<stamp>_<slug>` prefix.
- `unaccounted_ms` — `wall_ms` minus every known stage duration. A large residual names what this
  repo cannot yet see; it is a finding, not a defect.

Fail-open, unknown-is-`null` throughout (`build_timeline/3`, `timeline_ledger_rows/3`,
`cycle_wall_ms/1`): a `nil`/unresolvable `cycle_id`, an absent/malformed sibling ledger, or a
`gate-verdicts.jsonl` row predating the `cycle_id` field are all excluded rather than counted as a
zero-duration stage — an unjoinable row widens the residual, never shrinks it. A role call with no
captured duration projects `null` for that field, never a fabricated `0`. Additive-only: no existing
envelope key changes shape, and the one opaque whole-artifact reader
(`LoopQueue.transient?/1`'s `String.contains?(content, ~s("type":"result"))`) is unaffected by new
nested keys.

## Witness Extraction

`extract_witness <log_path>` — best-effort, fall-open-empty (never errors; missing witness never breaks
the gate). ExUnit-aware: finds the first `  N) test ...` headline block, prefers the stacktrace's first
frame over the raw definition line (definition line misleads on setup-raise and doctests). Falls back to
a generic `file:line` grep for credo/dialyzer-style output, then — when still empty — a doc-shaped
fallback: `grep -oE 'context/[A-Za-z0-9_-]+\.md|PROJECT_CONTEXT\.md'` (no `\b`, since GNU-grep's `\b` has
no guaranteed BSD ERE support and `required_platforms: [darwin, linux]`; the Elixir consumer's own
`\b`-anchored `@curator_owned_signatures` re-applies the boundary). Without it a doc-shaped gate failure
(e.g. `context-index-parity`, which names a file with no line number by construction) produced an empty
witness, and `resolve_gate_owner/2` fell back to the developer — who `subagent-read-discipline` then
denies the Read on that exact path. See `shared/rules/_core` § Witness Discipline for the cross-role
contract this feeds.

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

## `codegen-log init`

**The loop is the SOLE creator of a cycle's log.** It creates the log FIRST via **`codegen-log init --slug <slug> [--stamp <YYYYMMDD_HHMMSS>]`**, before any role spawns. `init` binds by **run identity**, never by slug alone: the log path is composed directly from `--stamp` (or, when omitted, `date -u +%Y%m%d_%H%M%S`) — there is no glob-by-slug lookup, so a retry of the same slug mints its OWN log instead of adopting a predecessor's. `init` IS idempotent at the exact-path level: re-`init` naming the SAME `--slug` AND `--stamp` (a path that already exists) prints that log's path and exits 0 without creating a second log or a duplicate `init` event. The loop always passes its own already-minted `stamp` (the same one that names the cycle's `cycle_id`/transcript dir), so this exact-match adoption is meaningful rather than accidental. `init` writes ONE `{"ev":"init",...}` event line and also writes `codegen/logging/.active` (a synchronous sentinel pointing at the resolved log path). A role (developer, reviewer, curator) MUST NOT run `codegen-log init` — see `shared/rules/_core/session-log.md` § Ownership. `init` refuses (exit 2, creates nothing, never touches `.active`) whenever `CODEGEN_LOG_PATH` is set in its environment — this is what stops a same-process `init` (e.g. from a mistyped slug) from minting a rival log and hijacking `.active` out from under every guard grading the real one.

## `codegen-log verdict`

**`codegen-log verdict --gate <cmd> --mode <mode> --result "<text>" [--detail "<text>"] --slug <slug>`** is the dedicated writer for the Elixir loop's LoopGate deterministic gate verdict (not written by a subagent). The loop calls this itself from `LoopGate.run_gate/2`, after every gate attempt, pinned to the cycle's own log via the `CODEGEN_LOG_PATH` env var it already holds (not `--slug` — the loop resolves the log path once at cycle start and threads it through as `CODEGEN_LOG_PATH`, same as every role invocation). Every call APPENDS a fresh `{"ev":"gate","role":"dev-gate",...}` event rather than replacing a prior one, since a cycle log commonly carries more than one dev-gate verdict across retries. `verdict` derives a classified `verdict` field (`clear`/`failed`/`inconclusive`) from the raw `--result` text (read from `gate-result.json`'s `verdict_marker` field, which alone preserves the inconclusive/failed distinction the loop's own binary `:clear | :failed` return value collapses) and stores both. A failed `codegen-log verdict` write is fail-loud-non-blocking — logged to stderr, never changes the gate's own returned verdict.

## `codegen-log exit` / `codegen-log committed`

**`codegen-log exit --status <n> [--signal <n>] [--stderr-tail "<text>"] [--slug <slug>]`** is the dedicated writer for the loop CHILD PROCESS's own raw wait status — written by `dispatch.sh` (both harness twins), from OUTSIDE any role (no role positional/flag; a process exit has no role). `--status` is the raw `wait` exit status (128+N = signal death, decodable via `--signal`); `--stderr-tail` carries the child's last ~8 KB of stderr when available (preserves a clean-exit raise's stacktrace even though nothing else durable does). Resolution mirrors `section`/`append` EXCEPT: when none of `CODEGEN_LOG_PATH`/`--slug`/`.active` resolve to an existing log, `exit` does NOT fail loud — it prints one stderr note and exits 0 without writing, because the loop may have died before it ever inited a log for this run, and that absence is itself the diagnostic (see `context/harnesses.md` § dispatch.sh). A failed `codegen-log exit` write is fail-loud-non-blocking — logged to stderr, never changes `dispatch.sh`'s own propagated exit code.

**`codegen-log committed --role <role> --sha <sha> --subject "<text>" [--slug <slug>]`** — loop-authored HEAD attribution; the loop asserts on its OWN pre/post HEAD samples, raising if ANY role moves HEAD (always authored `--role loop`; `codegen-commit` is the sole committer).

## `codegen-log show`

**`codegen-log show [<slug>] [--format table|md|html] [--role <role>] [--full] [--slug <slug>]`** is a READ-ONLY operator projection of one cycle log — it writes NOTHING, not the log, not `.active`, not a rendered file on disk; output goes to stdout only. It is an operator tool, not a cycle step — no role or subagent is taught to call it. Resolves the log via the SAME precedence as `section`/`append`, EXCEPT that a `--slug` matching more than one log (a retried slug) never refuses: `show` picks the NEWEST run by stamp and prints ONE stderr note naming the older log(s) — a bare positional argument is the slug (never a role — `show` has its own slug-only positional, distinct from `section`/`append`'s role positional). Builds a per-role spine, preferring (in order) the sibling `<log-dir>/<ts>_<slug>/cycle-summary.jsonl` (role/seq/num_turns/cost_usd/status/transcript), then the `ev:role` events themselves — each fallback prints one stderr note naming the spine used. `--format` (default `table`) also accepts `md` and `html` (html escapes every interpolated value via jq's `@html` filter); all three write to stdout only. `--role <role>` drills into that role's body/learning/transcript path; `--full` prints every role's body in `seq` order. Derives a fixed, deterministic anomaly list (a summary status other than `success`, any `ev:died`, an invoked role with zero `ev:role` body, a role with neither `ev:learned` nor `ev:no_learning`, a trailing gate verdict other than `clear`, any undeclared `ev` kind as `unknown event kind: <kind> (x<N>)`) — prints `no anomalies` explicitly when the list is empty, so a rogue write can never render as clean. Exits 2 (fail loud, no partial render) on: an unrecognized `--format` value, `--role` naming a role absent from the resolved log, or no cycle log found at all; a malformed (non-JSON) log line also exits non-zero rather than rendering an incomplete cycle as if it were complete.

## `ev:waiver`

`{"ev":"waiver","role":<role>,"hook":<hook-id>,"slug":<slug>}` — a `waivable: true` guard was relaxed for this invocation because the in-flight `building/<slug>.md` declared it in `waives:`. Written by `_waiver.sh`/`waiver.ts` at grant — never hand-called.

## jq Canonical Reader Forms

Use these exact selectors:

- role body: `jq -e --arg r "<role>" 'select(.ev=="role" and .role==$r)' <file>`; text: swap `-e` for `-r ...|.body`
- gate: `jq -e 'select(.ev=="gate" and .verdict=="inconclusive"/"clear")' <file>`
- died: `jq -e 'select(.ev=="died")' <file>`; by kind add `and .kind=="interrupted"`
- learned: `jq -e --arg r "<role>" 'select(.ev=="learned" and .role==$r)' <file>`
- slug: `jq -r 'select(.ev=="init")|.pitch' <file>`
- files-to-touch/modified: `jq -e --arg p "<relpath>" 'select(.ev=="files_to_touch" and (.role=="loop")) | .files[]? | select(.==$p)' <file>` (developer role for files_modified)

All `jq -e` uses: exit 0 = at least one match, exit 1 = none. Wrap every `jq` in `2>/dev/null` on read paths (swallow malformed-line noise, fail-open) EXCEPT where a hard block requires certainty.

## Trigger Keywords

codegen-log, cycle log, gate-pending, gate-result.json, cycle-state.json, write_gate_result, derive_verdict, verdict truth table, extract_witness, witness fallback, doc-shaped witness, context-index-parity witness, witness discipline, gate-verdicts.jsonl, graded_tree_sha, ev kinds, .active sentinel, no git-tracked logs, no cross-box log transport, recovery dossier, dossier stages, machine-local gitignored ephemeral artifact, recoveries/<slug>/<txid>.json, schema_version, transaction identity, timeline, wall_ms, unaccounted_ms, preflight-timings.jsonl, cycle-summary.jsonl, emit_loop_telemetry, build_timeline, where did the time go, codegen-log init, codegen-log verdict, codegen-log exit, codegen-log committed, codegen-log show, ev waiver, jq canonical reader forms
