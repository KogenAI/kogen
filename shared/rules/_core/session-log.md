# Session Log

## File Naming

Canonical schema (single source of truth — hooks and guards match against this):

```
codegen/logging/[0-9]{8}_[0-9]{6}_[a-z0-9_-]+_cycle\.jsonl$
```

- `./codegen/logging/$(date -u +%Y%m%d_%H%M%S)_<slug>_cycle.jsonl`

On-disk storage is **append-only JSONL** — one JSON object per line, one typed event per call, NEVER rewritten or ranked. Every event carries an `"ev"` discriminator (`init`/`role`/`learned`/`no_learning`/`died`/`gate`/`plan_gate`/`files_to_touch`/`files_modified`/`exit`/`committed`). A cycle log is a flat, growing list of events in call order — no ordering/rank concept.

## Path Discipline

ALL roles MUST use relative paths OR absolute paths starting with cwd for cycle logs, project files, and git operations.

## Git Status

Cycle logs live under `/codegen/` and are **gitignored** — in the codegen repo (`.gitignore`) and in every scaffolded downstream app (both stacks, appended by `codegen-scaffold` integrate). They are **ephemeral working artifacts — never committed, never durable**.

- NEVER `git add` a cycle log or include one in a commit. `git add -A` already skips gitignored logs.
- NEVER make a separate "record the log" commit — git refuses the ignored path (`exit 1`, "paths are ignored… Use -f") and the log never registers dirty under `git status --porcelain`, so nothing is missing.

## Ownership

**`codegen-log` is the SOLE writer of cycle logs.** Raw Edit/Write/MultiEdit on `codegen/logging/*.jsonl`, and raw Bash writes (redirect, tee, in-place stream-edit, move/copy into the path) are DENIED by the `session-log-writer-only` hook.

**THIS SECTION is the ONE authoritative CLI contract for `codegen-log`** — never re-teach the flag forms. Prefer the `mcp__codegen__*` tool when granted; the CLI stays for scripts/hooks/humans.

- **The loop is the SOLE creator of a cycle's log.** It creates the log FIRST via **`codegen-log init --slug <slug> [--stamp <YYYYMMDD_HHMMSS>]`**, before any role spawns. `init` binds by **run identity**, never by slug alone: the log path is composed directly from `--stamp` (or, when omitted, `date -u +%Y%m%d_%H%M%S`) — there is no glob-by-slug lookup, so a retry of the same slug mints its OWN log instead of adopting a predecessor's. `init` IS idempotent at the exact-path level: re-`init` naming the SAME `--slug` AND `--stamp` (a path that already exists) prints that log's path and exits 0 without creating a second log or a duplicate `init` event. The loop always passes its own already-minted `stamp` (the same one that names the cycle's `cycle_id`/transcript dir), so this exact-match adoption is meaningful rather than accidental. `init` writes ONE `{"ev":"init",...}` event line and also writes `codegen/logging/.active` (a synchronous sentinel pointing at the resolved log path — see Resolution below). **A role (planner, developer, reviewer, curator, committer) MUST NOT run `codegen-log init`.** Every role invocation already carries `CODEGEN_LOG_PATH` pinned to the cycle's own log — `section`/`append` resolve it automatically, so a role never needs to create or locate a log of its own. `init` refuses (exit 2, creates nothing, never touches `.active`) whenever `CODEGEN_LOG_PATH` is set in its environment — this is what stops a same-process `init` (e.g. from a mistyped slug) from minting a rival log and hijacking `.active` out from under every guard grading the real one.
- **Positional role (taught/default form)**: `codegen-log section <role> --slug <slug>` and `codegen-log append <role> --slug <slug>` read the role as the first bare argument after the subcommand. `--body` is implicit stdin when omitted — pipe the body directly: `printf '%s' "$body" | codegen-log section developer-phoenix-backend --slug <slug>`. `--body "<literal text>"` (no leading `@`) is also accepted directly, same as piping. `--role <role>` and `--body @-` remain accepted ALIASES for existing callers; a bare `codegen-log section` with no role (positional or `--role`) always exits 2, even if ambient `AGENT_TYPE`/`CLAUDE_ROLE` env vars are set — the role must be passed explicitly.
- **`codegen-log section <role> --slug <slug>`** (piping the body via stdin) APPENDS one `{"ev":"role","role":<role>,"body":<prose>}` event line: planner, developers, reviewer, curator, and committer each write their own body. Re-running `section` for the same role APPENDS another event line — there is nothing to overwrite, so a second call is never a mistake, just another entry in the log. **`section` also accepts an optional `--learned "<text>"`** — when present, the SAME call APPENDS a second `{"ev":"learned","role":<role>,"text":<t>}` event immediately after the `role` event, so the compliant path for recording both work and learning is one call: `printf '%s' "$body" | codegen-log section <role> --learned "<text>" --slug <slug>`. `section` NEVER refuses a write for omitting `--learned` — it stays fully optional there; see § Enforcement for what checks it.
- **`codegen-log append <role> --learned "<text>" --slug <slug>`** appends a `{"ev":"learned",...}` event. **`codegen-log append <role> --no-learning "<text>" --slug <slug>`** appends a `{"ev":"no_learning",...}` event — the legal, countable way to report a turn that produced no transferable learning (see § Substance Filter below); it satisfies § Subagent Retrospective in place of `--learned`. **`codegen-log append <role> --died interrupted|aborted [--cause "<text>"] --slug <slug>`** appends a `{"ev":"died",...}` event (see Death Stamps below). **`codegen-log append <role> --verdict clear|failed|inconclusive --slug <slug>`** appends a `{"ev":"gate","verdict":<v>,...}` event the loop's own gate-verdict readers select on. `append` with a plain `--body` (no marker flag) appends another `{"ev":"role",...}` event — the same shape `section` writes. JSONL append is unconditional: there is no "section must exist first" precondition.
- **`codegen-log verdict --gate <cmd> --mode <mode> --result "<text>" [--detail "<text>"] --slug <slug>`** is the dedicated writer for the Elixir loop's LoopGate deterministic gate verdict (not written by a subagent). The loop calls this itself from `LoopGate.run_gate/2`, after every gate attempt, pinned to the cycle's own log via the `CODEGEN_LOG_PATH` env var it already holds (not `--slug` — the loop resolves the log path once at cycle start and threads it through as `CODEGEN_LOG_PATH`, same as every role invocation). Every call APPENDS a fresh `{"ev":"gate","role":"dev-gate",...}` event rather than replacing a prior one, since a cycle log commonly carries more than one dev-gate verdict across retries. `verdict` derives a classified `verdict` field (`clear`/`failed`/`inconclusive`) from the raw `--result` text (read from `gate-result.json`'s `verdict_marker` field, which alone preserves the inconclusive/failed distinction the loop's own binary `:clear | :failed` return value collapses) and stores both. A failed `codegen-log verdict` write is fail-loud-non-blocking — logged to stderr, never changes the gate's own returned verdict.
- **`codegen-log append <role> --plan @-` / `--plan-gate @-` / `--files-to-touch @-` / `--files-modified @-`** are typed writers for the PLAN, gate-SELECTION, and read-discipline markers — first-class JSONL events, never re-parsed out of a role's free-form `body`. `--plan` pipes RAW TEXT (markdown, not JSON, same `@-`/`@-file` convention as `--body`) → `{"ev":"plan","plan":<text>,...}`; blank exits 2. `--plan-gate` pipes a JSON object (`{"command":<cmd>,"mode":"short"|"long","timeout":<seconds>}`, all REQUIRED) → `{"ev":"plan_gate",...}`; shape-validated at write. `--files-to-touch`/`--files-modified` pipe a JSON array of relative paths → matching `ev` kinds. Append-only; mutually exclusive with `--body`/`--learned`/`--no-learning`/`--died`/`--verdict`. Planner authors `plan`/`plan_gate`/`files_to_touch`; developer authors `files_modified`. Consumers read the AUTHOR's event, never the caller's own body, fail closed when absent — no prose fallback. `resolve_planner_plan!/2` raises before a developer runs when `plan` is absent or blank.
- **`codegen-log relocate --new-slug <slug> [--slug <slug>]`** renames the currently-resolved log in place and rewrites `.active` to the new path — used when a slug needs to change mid-cycle without losing log continuity.
- **`codegen-log exit --status <n> [--signal <n>] [--stderr-tail "<text>"] [--slug <slug>]`** is the dedicated writer for the loop CHILD PROCESS's own raw wait status — written by `dispatch.sh` (both harness twins), from OUTSIDE any role (no role positional/flag; a process exit has no role). `--status` is the raw `wait` exit status (128+N = signal death, decodable via `--signal`); `--stderr-tail` carries the child's last ~8 KB of stderr when available (preserves a clean-exit raise's stacktrace even though nothing else durable does). Resolution mirrors `section`/`append` EXCEPT: when none of `CODEGEN_LOG_PATH`/`--slug`/`.active` resolve to an existing log, `exit` does NOT fail loud — it prints one stderr note and exits 0 without writing, because the loop may have died before it ever inited a log for this run, and that absence is itself the diagnostic (see `context/harnesses.md` § dispatch.sh). A failed `codegen-log exit` write is fail-loud-non-blocking — logged to stderr, never changes `dispatch.sh`'s own propagated exit code. **`codegen-log committed --role <role> --sha <sha> --subject "<text>" [--slug <slug>]`** — loop-authored HEAD attribution per role-step; asserts on OWN samples, fails loud when `role` != `"committer"`.
- **`codegen-log show [<slug>] [--format table|md|html] [--role <role>] [--full] [--slug <slug>]`** is a READ-ONLY operator projection of one cycle log — it writes NOTHING, not the log, not `.active`, not a rendered file on disk; output goes to stdout only. It is an operator tool, not a cycle step — no role or subagent is taught to call it. Resolves the log via the SAME precedence as `section`/`append` (below), EXCEPT that a `--slug` matching more than one log (a retried slug) never refuses: `show` picks the NEWEST run by stamp and prints ONE stderr note naming the older log(s) — a bare positional argument is the slug (never a role — `show` has its own slug-only positional, distinct from `section`/`append`'s role positional). Builds a per-role spine, preferring (in order) the sibling `<log-dir>/<ts>_<slug>/cycle-summary.jsonl` (role/seq/num_turns/cost_usd/status/transcript), then the `ev:role` events themselves — each fallback prints one stderr note naming the spine used. `--format` (default `table`) also accepts `md` and `html` (html escapes every interpolated value via jq's `@html` filter); all three write to stdout only. `--role <role>` drills into that role's body/learning/transcript path; `--full` prints every role's body in `seq` order. Derives a fixed, deterministic anomaly list (a summary status other than `success`, any `ev:died`, an invoked role with zero `ev:role` body, a role with neither `ev:learned` nor `ev:no_learning`, a trailing gate verdict other than `clear`, any undeclared `ev` kind as `unknown event kind: <kind> (x<N>)`) — prints `no anomalies` explicitly when the list is empty, so a rogue write can never render as clean. Exits 2 (fail loud, no partial render) on: an unrecognized `--format` value, `--role` naming a role absent from the resolved log, or no cycle log found at all; a malformed (non-JSON) log line also exits non-zero rather than rendering an incomplete cycle as if it were complete.
- **`codegen-log corpus publish`/`corpus sync`** carry `*_cycle.jsonl` across boxes on orphan branch `refs/heads/corpus`, so the corpus survives one machine (logs stay gitignored). Codegen-repo-only: no-op unless `shared/enforcement/registry.yaml` exists (same sentinel as `gate-verdicts.jsonl`). Never role-authored — loop calls both (`sync` pre-`init`, `publish` at cycle tail), fail-loud-non-blocking. `publish` resolves via `CODEGEN_LOG_PATH` ONLY, never opens the repo's git index (hash-object + temp index + commit-tree onto fetched tip), retries once on non-fast-forward. `sync` materializes canonical branch files absent locally, mtime from filename (never "now") so it can't win mtime-fallback below.
- Subagents write body under their role via the writer — never emit or pre-seed placeholder events themselves.
- A role with zero `role`/`learned` events is invalid: every required role must have written at least one event with real content before the next role may spawn or the build may ship.
- **`--slug <slug>` is the recommended/default form** — pass it whenever the slug is known: the orchestrator always knows it after `codegen-log init --slug <slug>`, and MUST pass the same `<slug>` into every subagent's delegation prompt text so the subagent can pass it back to `codegen-log section`/`append`. This pins writes to the correct log in concurrent multi-slug builds. Omit `--slug` only when the slug genuinely isn't known at call time (manual/human CLI use).
- **Resolution precedence** when `codegen-log section`/`append`/`verdict`/`relocate`/`committed` (all WRITES) run: `CODEGEN_LOG_PATH` env var (if set) > `--slug` (resolves to the single on-disk log matching `*_<slug>_cycle.jsonl`; zero/multiple matches exit 2) > `.active` sentinel (if it points at a log that still exists) > most recently modified `*_cycle.jsonl` (mtime) — safety net when both `--slug` and a live sentinel are omitted. `show` (the one READ) shares this precedence except at the `--slug` rung, where multiple matches resolve to the newest rather than refusing (see above).

## Substance Filter

`codegen-log` is the SOLE writer of the cycle log (append-only — nothing can retract a bad line once written), so it is the one place that can refuse a lie before it becomes permanent. A `--learned` text, a `--no-learning` text, or a `section`/`append` role BODY is REFUSED (exit 2, writes nothing) when the ENTIRE trimmed text is a whole-text placeholder token (`test body`, `placeholder`, `dummy`, `lorem ipsum`, `nothing notable`, …) OR the text contains a compliance-echo phrase — text that describes the retrospective CHECK rather than the work (`long enough`, `at least forty/40 characters`, `passes the … bar`, `for testing`, `non-triviality bar`). The match is never a length floor: a real slug body like `placeholder-project-context-fix` survives — it is not, in its entirety, one of the deny-listed phrases. On refusal, `codegen-log` prints a message naming what is wrong, never what would pass.

## Death Stamps

When a role's invocation drops mid-response, the loop records it via `codegen-log append <role> --died <kind> --cause "<text>"` (`OrchestrationLoop.invoke_with_retry/4`), pinned via `CODEGEN_LOG_PATH`:

- `interrupted` — written on the FIRST invocation failure, before the loop's single retry runs (even when the retry recovers).
- `aborted` — written when the retry ALSO fails, immediately before the stage halts with `{:error, reason}`.

No `resumed` kind — a successful re-spawn just appends the role's normal `role`/`learned` events after `died`, in call order. A failed `--died` write is fail-loud-non-blocking.

## Enforcement

**Enforced by** the `session-log-writer-only` hard-deny hook (Claude + Pi twins) — catalog in `context/hooks.md`; enumerate via `grep -rlE 'session.?log|codegen/logging' harnesses/claude/hooks/*.sh`.

**Also enforced by** `role-retrospective-before-stop` (Claude: blocking `Stop` hook; Pi: observe-only twin) — a planner/developer/reviewer ending its turn without BOTH a non-empty `ev:role` body AND EITHER `ev:learned` OR `ev:no_learning` for its own role is pushed back (Claude) or warned on stderr (Pi). PRESENCE only — substance enforced upstream by `codegen-log` (§ Substance Filter). Bounded at 3 attempts, then falls through loud — never fails the build. `context-curator`/`committer` NOT gated.

## Event Schema

Every event object has an `"ev"` discriminator field:

- `{"ev":"init","pitch":<slug>,"path":<pitch-path-or-empty>,"stamp":{"project","context","codegen","claude","at"}}`
- `{"ev":"role","role":<role>,"body":<prose>}`
- `{"ev":"learned","role":<role>,"text":<t>}`
- `{"ev":"no_learning","role":<role>,"text":<t>}` — the legal, countable "this turn produced nothing to learn" exit; curator-invisible (curator reads `ev:learned` only)
- `{"ev":"died","role":<role>,"kind":"interrupted"|"aborted","cause":<c-or-empty>}`
- `{"ev":"gate","role":<role>,"verdict":"clear"|"failed"|"inconclusive","detail":<witness-or-sentinel-or-empty>, ...gate metadata for the `verdict` subcommand}` — `detail` is non-empty on any non-clear verdict: the located witness, or a named sentinel (`no parseable failure location in <N>-byte gate log` / `gate produced no output`) when none was locatable.
- `{"ev":"plan","role":<role>,"plan":<text>}` — planner's typed PLAN document; written via `--plan @-`. Developer/reviewer's `## Plan` threads from this event, never the role body prose.
- `{"ev":"plan_gate","role":<role>,"command":<cmd>,"mode":"short"|"long","timeout":<seconds>}` — planner's typed gate SELECTION (distinct from the `gate` verdict event above); written via `codegen-log append <role> --plan-gate @-`
- `{"ev":"files_to_touch","role":<role>,"files":[<relpath>,...]}` — planner's typed files-to-touch list; written via `codegen-log append <role> --files-to-touch @-`
- `{"ev":"files_modified","role":<role>,"files":[<relpath>,...]}` — developer's typed files-modified list; written via `codegen-log append <role> --files-modified @-`
- `{"ev":"exit","status":<n>,"signal":<n-or-null>,"stderr_tail":<text-or-empty>}` — `dispatch.sh`'s record of the loop child process's raw wait status; NO `role` field. Written via `codegen-log exit --status <n> [--signal <n>] [--stderr-tail "<text>"]`. `{"ev":"committed","role":<role>,"sha":<sha>,"subject":<subject>}` — loop's per-role HEAD attribution, never role-authored.
- `{"ev":"waiver","role":<role>,"hook":<hook-id>,"slug":<slug>}` — a `waivable: true` guard was relaxed for this invocation because the in-flight `building/<slug>.md` declared it in `waives:`. Written by `_waiver.sh`/`waiver.ts` at grant — never hand-called.

These markers are first-class JSONL events, never re-parsed out of a role's free-form `body` prose.

**Reader jq canonical forms** (use these exact selectors):

- role body: `jq -e --arg r "<role>" 'select(.ev=="role" and .role==$r)' <file>`; text: swap `-e` for `-r ...|.body`
- gate: `jq -e 'select(.ev=="gate" and .verdict=="inconclusive"/"clear")' <file>`
- died: `jq -e 'select(.ev=="died")' <file>`; by kind add `and .kind=="interrupted"`
- learned: `jq -e --arg r "<role>" 'select(.ev=="learned" and .role==$r)' <file>`
- slug: `jq -r 'select(.ev=="init")|.pitch' <file>`
- plan (last-wins): `jq -c 'select(.ev=="plan" and (.role|startswith("planner")))' <file> | tail -n 1`; same for `.ev=="plan_gate"`
- files-to-touch/modified: `jq -e --arg p "<relpath>" 'select(.ev=="files_to_touch" and (.role|startswith("planner"))) | .files[]? | select(.==$p)' <file>` (developer role for files_modified)

All `jq -e` uses: exit 0 = at least one match, exit 1 = none. Wrap every `jq` in `2>/dev/null` on read paths (swallow malformed-line noise, fail-open) EXCEPT where a hard block requires certainty.

## Subagent Retrospective — Required, Not Convention

Every planner/developer/reviewer role MUST record its learning as a typed event — via `codegen-log section <role> --learned "<text>" --slug <slug>` (the one-call compliant path) or a follow-up `codegen-log append <role> --learned "<text>" --slug <slug>`. This is enforced, not a convention: `role-retrospective-before-stop` (§ Enforcement above) blocks the role's Stop until the cycle log carries BOTH a non-empty `ev:role` body AND EITHER an `ev:learned` OR an `ev:no_learning` event for the role. Substance — not length — is enforced at the writer: `codegen-log` refuses a whole-text placeholder or a compliance-echo phrase (§ Substance Filter above) before it ever reaches the log.

When a turn genuinely produced no transferable learning, that is a legal, countable thing to say — record it with `codegen-log append <role> --no-learning "<what the turn did instead>" --slug <slug>` in place of `--learned`. The `--no-learning` text is subject to the same substance filter (it must say what the turn did, e.g. `refused: handoff named no files, reviewed zero code`), so the exit is honest, not cheaper. A `no_learning` event satisfies the Stop hook the same as a `learned` event, and is invisible to the context-curator (which reads `ev:learned` only) — it never becomes context landfill.

The role's BODY (the `ev:role` event, written via `section`) stays free-form prose — commands run, files touched, result summary. It is an opaque string; markdown-looking text inside it (e.g. `## Foo`) is never re-parsed as structure. A typical body:

```
**Rules loaded**: [x] <files>

**Commands executed**:
| Time (HH:MM:SS UTC) | Command | Exit | Notes |
| ------------------- | ------- | ---- | ----- |

**Files written/updated**: <list>

**Result**: <summary>
```

The learning goes in the SEPARATE `--learned` text, not inside this body — e.g.:

```
printf '%s' "$body" | codegen-log section developer-phoenix-backend \
  --learned "[local] Caught green-from-birth test in foo_test.exs: the fixture set the very variable under test, so the default branch never ran." \
  --slug <slug>
```

`--learned` requires leading tag, else exit 2: `[local]` = project. `[shared]` = framework. `--no-learning` exempt.

## Gate Verdict Authority

Gate hooks write `gate-result.json` with a `.verdict` field. Valid values: `"clear"`, `"failed"`, `"inconclusive"` only. **The `.verdict` JSON field is the authoritative gate result — never cosmetic log strings.** When a reviewer or the loop evaluates a gate's outcome, read `.verdict` from `gate-result.json`, not prose like "ALL CLEAR ✅" in the cycle log body. Log strings may reflect developer's intended state; JSON reflects the actual gate return code. Example: developer logs claim "ALL CLEAR ✅ on retry" but `gate-result.json` shows `.verdict: "failed"` — the JSON is authoritative and the gate truly failed.

## Citations — Cite `Module.function/arity` — never `file.ex:NN`. No module → section heading or unique nearby string.
