# Session Log

## File Naming

Canonical schema (single source of truth — hooks and guards match against this):

```
codegen/logging/[0-9]{8}_[0-9]{6}_[a-z0-9_-]+_cycle\.jsonl$
```

- `./codegen/logging/$(date -u +%Y%m%d_%H%M%S)_<slug>_cycle.jsonl`

On-disk storage is **append-only JSONL** — one JSON object per line, one typed event per call, NEVER rewritten or ranked. Every event object carries an `"ev"` discriminator field (`init`/`role`/`learned`/`died`/`gate`). A cycle log is a flat, growing list of events in call order — there is no section-ordering, header, or rank concept to enforce.

## Path Discipline

ALL roles MUST use relative paths OR absolute paths starting with cwd for cycle logs, project files, and git operations.

## Git Status

Cycle logs live under `/codegen/` and are **gitignored** — in the codegen repo (`.gitignore`) and in every scaffolded downstream app (both stacks, appended by `codegen-scaffold` integrate). They are **ephemeral working artifacts — never committed, never durable**.

- NEVER `git add` a cycle log or include one in a commit. `git add -A` already skips gitignored logs.
- NEVER make a separate "record the log" commit — git refuses the ignored path (`exit 1`, "paths are ignored… Use -f") and the log never registers dirty under `git status --porcelain`, so nothing is missing.

## Ownership

**`codegen-log` is the SOLE writer of cycle logs.** Raw Edit/Write/MultiEdit on `codegen/logging/*.jsonl`, and raw Bash writes (redirect, tee, in-place stream-edit, move/copy into the path) are DENIED by the `session-log-writer-only` hook.

**THIS SECTION is the ONE authoritative CLI contract for `codegen-log`.** Role rules and subagent templates reference it by name — they do not re-teach the flag forms.

- The loop creates the log FIRST via **`codegen-log init --slug <slug>`**. `init` is idempotent: re-`init` on an existing slug prints the existing log's path and exits 0 without creating a second log; more than one log matching the slug is ambiguous and exits 2. `init` writes ONE `{"ev":"init",...}` event line and also writes `codegen/logging/.active` (a synchronous sentinel pointing at the resolved log path — see Resolution below).
- **Positional role (taught/default form)**: `codegen-log section <role> --slug <slug>` and `codegen-log append <role> --slug <slug>` read the role as the first bare argument after the subcommand. `--body` is implicit stdin when omitted — pipe the body directly: `printf '%s' "$body" | codegen-log section developer-phoenix-backend --slug <slug>`. `--role <role>` and `--body @-` remain accepted ALIASES for existing callers; a bare `codegen-log section` with no role (positional or `--role`) always exits 2, even if ambient `AGENT_TYPE`/`CLAUDE_ROLE` env vars are set — the role must be passed explicitly.
- **`codegen-log section <role> --slug <slug>`** (piping the body via stdin) APPENDS one `{"ev":"role","role":<role>,"body":<prose>}` event line: planner, developers, reviewer, curator, and committer each write their own body. Re-running `section` for the same role APPENDS another event line — there is nothing to overwrite, so a second call is never a mistake, just another entry in the log.
- **`codegen-log append <role> --learned "<text>" --slug <slug>`** appends a `{"ev":"learned",...}` event. **`codegen-log append <role> --died interrupted|aborted [--cause "<text>"] --slug <slug>`** appends a `{"ev":"died",...}` event (see Death Stamps below). **`codegen-log append <role> --verdict clear|failed|inconclusive --slug <slug>`** appends a `{"ev":"gate","verdict":<v>,...}` event the loop's own gate-verdict readers select on. `append` with a plain `--body` (no marker flag) appends another `{"ev":"role",...}` event — the same shape `section` writes. JSONL append is unconditional: there is no "section must exist first" precondition.
- **`codegen-log verdict --gate <cmd> --mode <mode> --result "<text>" [--detail "<text>"] --slug <slug>`** is the dedicated writer for the Elixir loop's LoopGate deterministic gate verdict (not written by a subagent). The loop calls this itself from `LoopGate.run_gate/2`, after every gate attempt, pinned to the cycle's own log via the `CODEGEN_LOG_PATH` env var it already holds (not `--slug` — the loop resolves the log path once at cycle start and threads it through as `CODEGEN_LOG_PATH`, same as every role invocation). Every call APPENDS a fresh `{"ev":"gate","role":"dev-gate",...}` event rather than replacing a prior one, since a cycle log commonly carries more than one dev-gate verdict across retries. `verdict` derives a classified `verdict` field (`clear`/`failed`/`inconclusive`) from the raw `--result` text (read from `gate-result.json`'s `verdict_marker` field, which alone preserves the inconclusive/failed distinction the loop's own binary `:clear | :failed` return value collapses) and stores both. A failed `codegen-log verdict` write is fail-loud-non-blocking — logged to stderr, never changes the gate's own returned verdict.
- **`codegen-log relocate --new-slug <slug> [--slug <slug>]`** renames the currently-resolved log in place and rewrites `.active` to the new path — used when a slug needs to change mid-cycle without losing log continuity.
- Subagents write body under their role via the writer — never emit or pre-seed placeholder events themselves.
- A role with zero `role`/`learned` events is invalid: every required role must have written at least one event with real content before the next role may spawn or the build may ship.
- **`--slug <slug>` is the recommended/default form** — pass it whenever the slug is known: the orchestrator always knows it after `codegen-log init --slug <slug>`, and MUST pass the same `<slug>` into every subagent's delegation prompt text so the subagent can pass it back to `codegen-log section`/`append`. This pins writes to the correct log in concurrent multi-slug builds. Omit `--slug` only when the slug genuinely isn't known at call time (manual/human CLI use).
- **Resolution precedence** when `codegen-log section`/`append`/`verdict`/`relocate` run: `CODEGEN_LOG_PATH` env var (if set) > `--slug` (resolves to the single on-disk log matching `*_<slug>_cycle.jsonl`; zero or multiple matches exit 2) > `codegen/logging/.active` sentinel (if it points at a log that still exists on disk) > the most recently modified `*_cycle.jsonl` (mtime) — this fallback stays in place as the safety net for calls that omit both `--slug` and a live sentinel.

## Death Stamps

When a role's per-role invocation drops mid-response, the loop records it as a `{"ev":"died",...}` event on the dead role — written by the loop itself (`OrchestrationLoop.invoke_with_retry/4`), via `codegen-log append <role> --died <kind> --cause "<text>"` pinned to the cycle's own log through the same `CODEGEN_LOG_PATH` env var every role invocation carries:

- `{"ev":"died","role":<role>,"kind":"interrupted","cause":<cause>}` — written on the FIRST invocation failure, before the loop's single retry runs. Written even when the retry recovers — `interrupted` records a drop-and-respawn, not only a fatal one.
- `{"ev":"died","role":<role>,"kind":"aborted","cause":<cause>}` — written when the retry ALSO fails, immediately before the stage halts with `{:error, reason}`.

There is no `resumed` kind — no writer ever emits one; a successful re-spawn simply appends the role's normal `role`/`learned` events after the `died` event, in call order. A failed `codegen-log append --died` write is fail-loud-non-blocking — logged to stderr, never changes the loop's retry/halt control flow.

## Enforcement

**Enforced by** the `session-log-writer-only` hard-deny hook (Claude + Pi twins) — catalog in `context/hooks.md`; enumerate via `grep -rlE 'session.?log|codegen/logging' harnesses/claude/hooks/*.sh`.

## Event Schema

Every event object has an `"ev"` discriminator field:

- `{"ev":"init","pitch":<slug>,"path":<pitch-path-or-empty>,"stamp":{"project","context","codegen","claude","at"}}`
- `{"ev":"role","role":<role>,"body":<prose>}`
- `{"ev":"learned","role":<role>,"text":<t>}`
- `{"ev":"died","role":<role>,"kind":"interrupted"|"aborted","cause":<c-or-empty>}`
- `{"ev":"gate","role":<role>,"verdict":"clear"|"failed"|"inconclusive", ...gate metadata for the `verdict` subcommand}`

**Reader jq canonical forms** (use these exact selectors so all consumers agree):

- role body present: `jq -e --arg r "<role>" 'select(.ev=="role" and .role==$r)' <file>`
- concatenated role body text: `jq -r --arg r "<role>" 'select(.ev=="role" and .role==$r)|.body' <file>`
- inconclusive gate present: `jq -e 'select(.ev=="gate" and .verdict=="inconclusive")' <file>`
- clear gate present: `jq -e 'select(.ev=="gate" and .verdict=="clear")' <file>`
- death marker present: `jq -e 'select(.ev=="died")' <file>`; by kind: `select(.ev=="died" and .kind=="interrupted")`
- learned present for role: `jq -e --arg r "<role>" 'select(.ev=="learned" and .role==$r)' <file>`
- slug from init: `jq -r 'select(.ev=="init")|.pitch' <file>`

All `jq -e` uses: exit 0 = at least one match, exit 1 = none. Wrap every `jq` in `2>/dev/null` on read paths (swallow malformed-line noise, fail-open) EXCEPT where a hard block requires certainty.

## Subagent Retrospective Convention

A body written via `codegen-log section`/`append` is an opaque prose string — a body containing markdown-looking text (e.g. `## Foo`) is never re-parsed as structure. By convention, subagent bodies still include a `### What I Learned This Step` retrospective block so readers extracting retrospectives from the body string can find it consistently:

```
**Rules loaded**: [x] <files>

**Commands executed**:
| Time (HH:MM:SS UTC) | Command | Exit | Notes |
| ------------------- | ------- | ---- | ----- |

**Files written/updated**: <list>

**Result**: <summary>

### What I Learned This Step

- nothing notable
```

Tags: `[local]` = project-specific. `[shared]` = framework idioms, cross-cutting patterns.

## Gate Verdict Authority

Gate hooks write `gate-result.json` with a `.verdict` field (`"passed"` or `"failed"`). **The `.verdict` JSON field is the authoritative gate result — never cosmetic log strings.** When a reviewer or the loop evaluates a gate's outcome, read `.verdict` from `gate-result.json`, not prose like "ALL CLEAR ✅" in the cycle log body. Log strings may reflect developer's intended state; JSON reflects the actual gate return code. Example: developer logs claim "ALL CLEAR ✅ on retry" but `gate-result.json` shows `.verdict: "failed"` — the JSON is authoritative and the gate truly failed.

## Citations

Cite `Module.function/arity` — never `file.ex:NN`. No module → section heading or unique nearby string.
