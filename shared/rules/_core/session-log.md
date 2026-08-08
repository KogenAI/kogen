# Session Log

## File Naming

Canonical schema (single source of truth — hooks and guards match against this):

```
codegen/logging/[0-9]{8}_[0-9]{6}_[a-z0-9_-]+_cycle\.jsonl$
```

- `./codegen/logging/$(date -u +%Y%m%d_%H%M%S)_<slug>_cycle.jsonl`

On-disk storage is **append-only JSONL** — one JSON object per line, one typed event per call, NEVER rewritten or ranked. Every event carries an `"ev"` discriminator (`init`/`role`/`learned`/`no_learning`/`died`/`gate`/`files_to_touch`/`files_modified`/`exit`/`committed`). A cycle log is a flat, growing list of events in call order — no ordering/rank concept.

## Path Discipline

ALL roles MUST use relative paths OR absolute paths starting with cwd for cycle logs, project files, and git operations.

## Git Status

Cycle logs live under `/codegen/` and are **gitignored** — in the codegen repo (`.gitignore`) and in every scaffolded downstream app (both stacks, appended by `codegen-scaffold` integrate). They are **ephemeral working artifacts — never committed, never durable**.

- NEVER `git add` a cycle log or include one in a commit. `git add -A` already skips gitignored logs.
- NEVER make a separate "record the log" commit — git refuses the ignored path (`exit 1`, "paths are ignored… Use -f") and the log never registers dirty under `git status --porcelain`, so nothing is missing.

## Ownership

**`codegen-log` is the SOLE writer of cycle logs.** Raw Edit/Write/MultiEdit on `codegen/logging/*.jsonl`, and raw Bash writes (redirect, tee, in-place stream-edit, move/copy into the path) are DENIED by the `session-log-writer-only` hook.

**THIS SECTION is the ONE authoritative CLI contract for `codegen-log`** — never re-teach the flag forms. Prefer the `mcp__codegen__*` tool when granted; the CLI stays for scripts/hooks/humans.

- **A role (developer, reviewer, curator) MUST NOT run `codegen-log init`.** Every role invocation already carries `CODEGEN_LOG_PATH` pinned to the cycle's own log — `section`/`append` resolve it automatically, so a role never needs to create or locate a log of its own. Full `init` mechanics (run-identity binding, idempotence, `.active` sentinel, `CODEGEN_LOG_PATH` refusal) are owned by the loop, not a role — see `context/cycle-record.md` § `codegen-log init`.
- **Positional role (taught/default form)**: `codegen-log section <role> --slug <slug>` and `codegen-log append <role> --slug <slug>` read the role as the first bare argument after the subcommand. `--body` is implicit stdin when omitted — pipe the body directly: `printf '%s' "$body" | codegen-log section developer-phoenix-backend --slug <slug>`. `--body "<literal text>"` (no leading `@`) is also accepted directly, same as piping. `--role <role>` and `--body @-` remain accepted ALIASES for existing callers; a bare `codegen-log section` with no role (positional or `--role`) always exits 2, even if ambient `AGENT_TYPE`/`CLAUDE_ROLE` env vars are set — the role must be passed explicitly. **Accepted role vocabulary**: `loop` | `developer-*` | `reviewer-*` | `context-curator`. `loop` is the non-agent author the loop writes under (`files_to_touch`, `committed`); every other value names a subagent role.
- **`codegen-log section <role> --slug <slug>`** (piping the body via stdin) APPENDS one `{"ev":"role","role":<role>,"body":<prose>}` event line: developers, reviewer, and curator each write their own body. Re-running `section` for the same role APPENDS another event line — there is nothing to overwrite, so a second call is never a mistake, just another entry in the log. **`section` also accepts an optional `--learned "<text>"`** — when present, the SAME call APPENDS a second `{"ev":"learned","role":<role>,"text":<t>}` event immediately after the `role` event, so the compliant path for recording both work and learning is one call: `printf '%s' "$body" | codegen-log section <role> --learned "<text>" --slug <slug>`. `section` NEVER refuses a write for omitting `--learned` — it stays fully optional there; see § Enforcement for what checks it.
- **`codegen-log append <role> --learned "<text>" --slug <slug>`** appends a `{"ev":"learned",...}` event. **`codegen-log append <role> --no-learning "<text>" --slug <slug>`** appends a `{"ev":"no_learning",...}` event — the legal, countable way to report a turn that produced no transferable learning (see § Substance Filter below); it satisfies § Subagent Retrospective in place of `--learned`. **`codegen-log append <role> --died interrupted|aborted [--cause "<text>"] --slug <slug>`** appends a `{"ev":"died",...}` event (see Death Stamps below). **`codegen-log append <role> --verdict clear|failed|inconclusive --slug <slug>`** appends a `{"ev":"gate","verdict":<v>,...}` event the loop's own gate-verdict readers select on. `append` with a plain `--body` (no marker flag) appends another `{"ev":"role",...}` event — the same shape `section` writes. JSONL append is unconditional: there is no "section must exist first" precondition.
- **`codegen-log verdict`** is the dedicated writer for the Elixir loop's LoopGate deterministic gate verdict — not written by a subagent. Full contract (flags, classification, fail-loud-non-blocking behavior): `context/cycle-record.md` § `codegen-log verdict`.
- **`codegen-log append <role> --files-to-touch @-` / `--files-modified @-`** are typed writers for the read-discipline markers — first-class JSONL events, never re-parsed out of a role's free-form `body`. Both pipe a JSON array of relative paths → matching `ev` kinds. Append-only; mutually exclusive with `--body`/`--learned`/`--no-learning`/`--died`/`--verdict`. The **loop** authors `files_to_touch` (`--role loop`), derived deterministically from the pitch's `scope:` frontmatter field — no agent writes it; the developer authors `files_modified`. Consumers read the AUTHOR's event, never the caller's own body, fail closed when absent — no prose fallback.
- **`codegen-log relocate --new-slug <slug> [--slug <slug>]`** renames the currently-resolved log in place and rewrites `.active` to the new path — used when a slug needs to change mid-cycle without losing log continuity.
- **`codegen-log exit`** and **`codegen-log committed`** are the dedicated writers for, respectively, the loop CHILD PROCESS's raw wait status (written by `dispatch.sh`, outside any role) and the loop's per-role HEAD-move attribution. Neither is called by a role. Full contract (flags, resolution quirks, fail-loud-non-blocking behavior): `context/cycle-record.md` § `codegen-log exit` / § `codegen-log committed`.
- **`codegen-log show`** is a READ-ONLY operator projection of one cycle log — no role or subagent is taught to call it. Full contract (resolution, spine derivation, `--format`, anomaly list, exit codes): `context/cycle-record.md` § `codegen-log show`.
- **Cycle logs MUST NEVER be carried through git.** Machine-local and gitignored is the whole contract — `codegen-log` has no publish/sync/export subcommand and never will. NEVER `git add`, `git hash-object`, `git commit-tree`, `git notes add`, `git stash`, or push a cycle log onto ANY branch/ref/note/stash, and NEVER build a wrapper (script, Mix task, CI step) that does so on your behalf. No replacement cross-box transport (branch, note, stash, or alternate mechanism) is planned or wanted. A cycle log surviving one machine is explicitly NOT a goal this codebase pursues.
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

**Enforced by** the `session-log-writer-only` hard-deny hook — catalog in `context/hooks.md`; enumerate via `grep -rlE 'session.?log|codegen/logging' harnesses/claude/hooks/*.sh`.

**Also enforced by** `role-retrospective-before-stop` (blocking `Stop` hook) — a developer/reviewer ending its turn without BOTH a non-empty `ev:role` body AND EITHER `ev:learned` OR `ev:no_learning` for its own role is pushed back. PRESENCE only — substance enforced upstream by `codegen-log` (§ Substance Filter). Bounded at 3 attempts, then falls through loud — never fails the build. `context-curator` NOT gated (the commit step is a script, not a role).

## Event Schema

Every event object has an `"ev"` discriminator field:

- `{"ev":"init","pitch":<slug>,"path":<pitch-path-or-empty>,"stamp":{"project","context","codegen","claude","at"}}`
- `{"ev":"role","role":<role>,"body":<prose>}`
- `{"ev":"learned","role":<role>,"text":<t>}`
- `{"ev":"no_learning","role":<role>,"text":<t>}` — the legal, countable "this turn produced nothing to learn" exit; curator-invisible (curator reads `ev:learned` only)
- `{"ev":"died","role":<role>,"kind":"interrupted"|"aborted","cause":<c-or-empty>}`
- `{"ev":"gate","role":<role>,"verdict":"clear"|"failed"|"inconclusive","detail":<witness-or-sentinel-or-empty>, ...gate metadata for the `verdict` subcommand}` — `detail` is non-empty on any non-clear verdict: the located witness, or a named sentinel (`no parseable failure location in <N>-byte gate log` / `gate produced no output`) when none was locatable.
- `{"ev":"files_to_touch","role":"loop","files":[<relpath>,...]}` — the LOOP's typed files-to-touch list, derived from the pitch's `scope:` frontmatter field; written via `codegen-log append loop --files-to-touch @-`. Always authored by `loop`, never by an agent role.
- `{"ev":"files_modified","role":<role>,"files":[<relpath>,...]}` — developer's typed files-modified list; written via `codegen-log append <role> --files-modified @-`
- `{"ev":"exit","status":<n>,"signal":<n-or-null>,"stderr_tail":<text-or-empty>}` — `dispatch.sh`'s record of the loop child process's raw wait status; NO `role` field. Written via `codegen-log exit --status <n> [--signal <n>] [--stderr-tail "<text>"]`. `{"ev":"committed","role":<role>,"sha":<sha>,"subject":<subject>}` — loop's per-role HEAD attribution, never role-authored.
- `{"ev":"waiver",...}` — a `waivable: true` guard was relaxed for this invocation, per the pitch's `waives:` declaration. Never hand-called — see `context/cycle-record.md` § `ev:waiver`.

These markers are first-class JSONL events, never re-parsed out of a role's free-form `body` prose.

Canonical `jq` reader forms (for hook/loop authors, not roles): `context/cycle-record.md` § jq Canonical Reader Forms.

## Subagent Retrospective — Required, Not Convention

Every developer/reviewer role MUST record its learning as a typed event — via `codegen-log section <role> --learned "<text>" --slug <slug>` (the one-call compliant path) or a follow-up `codegen-log append <role> --learned "<text>" --slug <slug>`. This is enforced, not a convention: `role-retrospective-before-stop` (§ Enforcement above) blocks the role's Stop until the cycle log carries BOTH a non-empty `ev:role` body AND EITHER an `ev:learned` OR an `ev:no_learning` event for the role. Substance — not length — is enforced at the writer: `codegen-log` refuses a whole-text placeholder or a compliance-echo phrase (§ Substance Filter above) before it ever reaches the log.

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
