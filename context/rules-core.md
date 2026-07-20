# Rules Core Domain — Cross-Cutting Discipline Rules

Core discipline rules that apply to ALL agents regardless of role or stack. These files are `{% include %}`d into every subagent template — they encode the baseline behavioral contract every agent must follow.

## Components

| File                                              | Purpose                                                                |
| ------------------------------------------------- | ---------------------------------------------------------------------- |
| `shared/rules/INDEX.md`                           | Registry — file → trigger keywords; loaded by orchestrators/planners   |
| `shared/rules/STYLE_GUIDE.md`                     | Cross-cutting style rules for all agents                               |
| `shared/rules/_core/bash-discipline.md`           | Forbidden bash patterns, token-budget rules, safe alternatives         |
| `shared/rules/_core/output-style.md`              | Caveman Ultra output compression rules                                 |
| `shared/rules/_core/session-log.md`               | Session log format, ownership, section headers, subagent body template |
| `shared/rules/_core/cwd-discipline.md`            | Working-directory rules — no /tmp writes, absolute paths only          |
| `shared/rules/_core/fail-fast-required-values.md` | Masking-default detection: 3-part test for required-value defaults     |
| `shared/rules/_core/fail-loud.md`                 | Universal fail-loud posture: forbidden swallows/silent-defaults        |
| `shared/rules/_core/witness-discipline.md`        | FAILED-gate witness requirement (file:line + verbatim cause)           |

## Key Paths

```
shared/rules/
  INDEX.md
  STYLE_GUIDE.md
  _core/
    bash-discipline.md
    output-style.md
    session-log.md
    cwd-discipline.md
    fail-fast-required-values.md
    fail-loud.md
    witness-discipline.md
```

## Integration Points

- **subagents**: `_core` rules are `{% include %}`d selectively per role — NOT every subagent includes all 7. Check each `.md.j2` template for exact includes. Changes require `make install` to propagate
- **shape spine**: The authoring spine (`_authoring-spine.txt`, included in shape mode body) enforces the "plain-language discipline" rule (Rule B), which cites `output-style.md` § Verbatim to define protected literal categories (code blocks, error strings, JSON field names, `MUST`/`NEVER`/`FORBIDDEN`, gate markers). The rule allows these literals to appear verbatim in user-facing prose while suppressing other internal shorthand.
- **hooks**: some hooks enforce these rules at runtime (e.g. `no-python-json.sh` enforces `bash-discipline.md`; `no-cat-pipe.sh` enforces pipe patterns) — see `context/hooks.md`
- **rules-roles**: role rules are layered on top of these core rules; core rules define the floor
- **INDEX.md must stay in sync** — each rule file must have an INDEX row or orchestrators won't load it on demand

## Trigger Keywords

bash-discipline, output-style, session-log, cwd-discipline, STYLE_GUIDE, INDEX.md, rule file organization, make install rebake

## POSIX Awk Patterns

**Uninitialized variable defaults**: POSIX awk initializes unset scalar variables to 0 (numeric context) or empty string (string context). Safe pattern for block-scoped search functions: `exit !found` at END correctly exits 1 (not found) when no matching line was found, without requiring explicit `found=0` initialization at the top. This works in all awk implementations including mawk (Debian default).

## Shared Rule Prose — Harness-Neutral & Consumer-Agnostic Language

Rules in `shared/rules/shared/` (and cross-referenced by downstream projects) must never name harness-specific binaries or codegen-internal dispatch mechanisms. These rules are baked into agent prompts executed in downstream projects where the named binaries may not exist.

**Anti-patterns**:

- ❌ `claude` / `pi` (harness binary names)
- ❌ `codegen-call` (codegen-internal dispatcher)
- ❌ `claude -p` / `pi -p` (harness-specific CLI flags)

**Harness-neutral equivalents**:

- ✅ "nested subprocess" (covers any role-spawning mechanism)
- ✅ `--print` (flag name is neutral; flag semantics apply to all harnesses)

The carve-out parenthetical is the most error-prone location for this slip — ensure any exception allowing subprocess invocation uses the neutral form. Example: "This does NOT forbid a print-mode subprocess (`--print`) your delegation prompt explicitly asks for — e.g. verifying a build, or testing a role you are editing."

## `codegen-log` Role Resolution

The `codegen-log` binary resolves role via precedence chain: `ROLE_OVERRIDE` env var (test-only) > `AGENT_TYPE` env var (shape/ops/debug launchers) > `CLAUDE_ROLE` env var (legacy, shape-mode only) > `--role <literal>` flag. The env-var fallback is kept (valid for non-build launchers), but **build subagents spawned via `codegen-build` Task export NO role env vars** — they must use `--role <literal>` explicitly in their `codegen-log section`/`append` instructions. Teaching every subagent prompt to emit the literal ensures correct role resolution across all contexts (build + shape + debug).

## Typed Marker Flags — `--plan` / `--plan-gate` / `--files-to-touch` / `--files-modified`

PLAN, gate-SELECTION, and read-discipline markers are first-class JSONL events (`ev:plan`/`ev:plan_gate`/`ev:files_to_touch`/`ev:files_modified`), written via typed `codegen-log append <role> --plan|--plan-gate|--files-to-touch|--files-modified @-` calls — never re-parsed out of a role's free-form `body` prose. planner* authors `plan` (the full plan document, threaded verbatim under `## Plan` to developer/reviewer by `OrchestrationLoop.resolve_planner_plan!/2` → `LoopGate.planner_plan/1`), `plan_gate` (gate command/mode/timeout), and `files_to_touch` (the files a developer may Read `context/*.md`under); developer* authors`files_modified`(the files a reviewer may Read`context/\*.md`under).`gate-select.sh`(`gate_select_read_planner_plan`/`gate_select_read_planner_gate`) and`subagent-read-discipline.sh`read the field from its AUTHOR's event, never the calling role's own — a caller-authored self-read cannot self-authorize a Read. An absent or blank `plan`event raises before a developer is ever invoked — the developer's`## Plan` slot holds a plan, or the cycle halts. Full contract:`shared/rules/\_core/session-log.md` § Ownership.

## FAILED-Gate Witness Requirement

A FAILED gate verdict MUST carry a **witness**: `file:line — <verbatim cause>`, located from the gate log rather than left for the next agent to re-derive. The witness travels three legs: (1) into `gate-result.json`'s `witness` field for the next role's delegation prompt (transient, overwritten every run); (2) into the cycle log's `{"ev":"gate"}` `detail` field via `codegen-log verdict --detail`, so the located cause survives past the run that produced it (durable, append-only); (3) onto the operator's own read surface, `codegen-log show`'s anomaly line (`trailing gate verdict: failed — <witness>`), across all three render formats. Absence of a witness never blocks the gate — `extract_witness` is fall-open-empty; a FAILED verdict whose located cause could not be parsed from the log records that fact (`no parseable failure location in <N>-byte gate log`) rather than a silently blank `detail`. Full contract: `shared/rules/_core/witness-discipline.md`.

## Pitfalls

- **Rule changes are not live** — must `make install` to regenerate agent prompts; running agents see old baked rules
- **INDEX.md must stay in sync** — adding a rule file without an INDEX row means orchestrators won't load it on demand
- **`@apply` in rules is Tailwind-context only** — static site rules reference Tailwind `@apply`; don't confuse with CSS `@apply`
- **Shared rules must be harness-agnostic** — no launcher/dispatcher binary names in files under `shared/rules/shared/` or symlink-included rules; these are baked into downstream agent prompts
- **[shared] Pure hard-delete safer than deprecation** — When deleting dead code (validator branches, special-cases), hard-delete entirely vs leaving always-false backstop. Pure deletion is verifiable by GREP (zero matches) and prevents future developers from resurrecting dead code without understanding the original boundary violation.
- **[shared] Stale-doc-twin defect** — Grep full vocabulary across ALL files when fixing drift.
- **Rule-file line caps are STYLE_GUIDE targets (advisory, for new files); the committed budget is the enforced number** — `_core/` rule files target <50 lines; `roles/` and `stacks/` target <150 lines, but `make prompt-size-budget` (component of `make test`) enforces each file's own row in `templates/generator/prompt-budgets.txt` instead, frozen at CURRENT size (several files already exceed the STYLE_GUIDE target as pre-existing scar tissue). The ceiling is operator-owned: `prompt-budget-writer-only` denies every agent write path to `prompt-budgets.txt` (Edit/Write/MultiEdit, the `--write` flag, Bash write-vocab) — a red verdict means shrink the file or evict the lowest-value content, never raise the cap. `context-curator-guard.sh`'s `warn_if_over_cap` predicts this SAME committed-budget row at edit time (curator-only, stderr-only, never blocks) — it no longer warns off the STYLE_GUIDE tier numbers, so a file already at its full committed budget warns correctly instead of staying silent (or vice versa). Only the `context/*.md` / `PROJECT_CONTEXT.md` / `codegen/PROJECT_CONTEXT.md` byte cap (40,960 B) is hook-enforced (denied) at Edit time.
