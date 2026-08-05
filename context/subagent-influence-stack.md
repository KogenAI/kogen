# LLM Influence Stack

> Where to look when an LLM subagent does the wrong thing, and where to add a constraint so it doesn't happen again.

## Layer Map

| #   | Layer                  | Where it lives                   | Who reads it                                   | When it applies                           |
| --- | ---------------------- | -------------------------------- | ---------------------------------------------- | ----------------------------------------- |
| 1   | Shared rules           | OCG shared rules dir             | Subagents (baked), orchestrator (live via `@`) | Every invocation                          |
| 2   | Subagent system prompt | `~/.claude/agents/<role>.md`     | Subagent on spawn                              | Every subagent invocation                 |
| 3   | Project context files  | `./context/*.md`                 | Orchestrator + curator; a cycle role only per typed grant | When the loop's `files_to_touch` lists the path |
| 4   | Runtime CLI flags      | Built by your platform's harness | Claude Code CLI                                | Per-invocation; append-only               |
| 5   | Hooks                  | `~/.claude/hooks/*.sh`           | Claude Code runtime                            | On tool use / subagent stop / stop events |
| 6   | Recipes                | `./codegen/recipes/`             | Developer on demand                            | When known pattern matches task           |

## Layer 1 — Shared Rules (baked into system prompt)

Source: OCG `shared/rules/` directory (canonical root differs across machines AND OSes — Linux servers + the Hetzner dashboard box, and operator Macs — so it is never hardcoded; e.g. `~/apps/codegen/shared/rules/` on the box vs `~/Areas/Optimum/codegen/shared/rules/` on a Mac. See `context/deployment-topology.md`). Baked into subagent prompts via Jinja `{% include %}` in templates under `shared/subagents/`. `make install` regenerates `~/.claude/agents/*.md` and commits to each project.

Orchestrator loads rules LIVE at session start via `@codegen/rules/...` auto-includes. Subagents only see what was baked at last `make install`. Diverge silently if `make install` skipped after edit.

Scope: editing any file under `shared/rules/` or `codegen/templates/` → MUST run `make install`. (`codegen/rules/` is a symlink to `shared/rules/` post-install; edit `shared/rules/` directly, not through the symlink.)

## Layer 2 — Subagent System Prompt

File: `~/.claude/agents/<role>.md`. Generated from `<role>.md.j2` template. Contains baked rules + role contract (slice scope, gate command, output style). Subagent reads this on every spawn — can't be changed mid-session without `make install` + re-spawn.

To inspect what a subagent actually has: Read tool on `~/.claude/agents/<role>.md` (Example: `~/.claude/agents/developer-phoenix-backend.md`).

**Build mode has no self-orchestrating prompt anymore** — `codegen-build` always drives the deterministic Elixir orchestration loop (`mix codegen.loop`), which invokes each role directly via `codegen-call` and writes each role's session-log section itself. There is no `build` manifest mode, no baked build system prompt, and no `tools-header/build.txt` file. The step-0 cycle-log ritual (`codegen-log init --slug <slug> --stamp <ts>` with canonical name `YYYYMMDD_HHMMSS_slug_cycle.jsonl` — the loop's own already-minted `stamp` supplies the `<ts>`, binding the log to this RUN's identity rather than a slug-only lookup, so a retry mints its own log) is performed by the loop itself, not by prompt instruction — `codegen-log` remains the sole writer of cycle logs (`session-log-writer-only` denies any raw Edit/Write/Bash-redirect alternative).

## Layer 3 — Project Context Files

Files: `./context/*.md`. NOT auto-loaded into subagent prompts. Audience = the interactive orchestrator (reads on demand based on trigger keywords in `PROJECT_CONTEXT.md`) and the context-curator (writes them post-reviewer). A cycle role never browses them: `subagent-read-discipline.sh` denies `PROJECT_CONTEXT.md` outright to `developer-*`/`reviewer-*`/`committer`, and allows a `context/*.md` Read ONLY when that exact path appears in a typed grant — the LOOP's `{"ev":"files_to_touch","role":"loop",...}` event for the developer, the DEVELOPER's `{"ev":"files_modified",...}` event for the reviewer. The loop derives `files_to_touch` from the pitch's `scope:` frontmatter field, so a context file reaches a developer only because the pitch declared it.

## Layer 4 — Runtime CLI Flags

Built by the consuming platform's harness-config builder (Example: returns `%{cli_flags, ...}`). Key flags:

| Flag                             | Used for                                                                         |
| -------------------------------- | -------------------------------------------------------------------------------- |
| `--system-prompt`                | All four launchers; replaces system prompt                                       |
| `--tools`                        | Tool allowlist; MUST be appended AFTER prompt positional (variadic ordering bug) |
| `--json-schema`                  | Inline JSON string only — NOT `@path`                                            |
| `--model`                        | Per-chain model selection                                                        |
| `--dangerously-skip-permissions` | `claude-build` non-interactive mode                                              |

`--tools` does NOT constrain `subagent_type` — that gating lives in hooks (Layer 5). `--exclude-dynamic-system-prompt-sections` is no-op when `--system-prompt` is set.

## Layer 5 — Hooks

Files: `~/.claude/hooks/*.sh` (installed via `make install`). Fire on `PreToolUse` / `PostToolUse` / `SubagentStop` / `Stop` events. NEVER edit `~/.claude/hooks/*.sh` directly — overwritten by next `make install`. Edit template in OCG `harnesses/claude/hooks/`, update `*_test.sh`, run `make test`, then `make install`.

Two discriminators:

- `AGENT_TYPE` — per-subagent identity (inner). Use for per-role guards.
- `CLAUDE_ROLE` — per-launcher mode (outer). Use for `claude-debug`/`claude-shape` session guards.

Hooks can't read LLM output content — only tool calls and subagent identity. `SubagentStart` CANNOT block (inject context only). All subagent gating uses `PreToolUse` on `Agent` matched by `tool_input.subagent_type`.

Key enforcement hooks (Examples): `orchestrator-no-source-edit.sh` (write surface), `dev-no-ci.sh` (blocks gate commands + bare test runners), `pre-commit-guard.sh` (blocks git commit for non-committer), `operator-subagent-allowlist.sh` (blocks `Plan`/`general-purpose` built-ins). For non-interactive builds, the gate is owned by the Elixir loop's `LoopGate`, not a SubagentStop hook.

## Layer 6 — Recipes

Files: `./codegen/recipes/`. Read ON DEMAND by the developer when a known pattern matches. Not auto-loaded. Named by the pitch (or eagerly `{% include %}`d into the role template when the pattern applies to every invocation — see `context/subagents.md` § Eager-vs-Lazy Include Discipline).

---

## Debugging Checklist

Work top-down when subagent does wrong thing:

1. **Rule exists but subagent ignored it** → was `make install` run after editing? Check `~/.claude/agents/<role>.md` for the rule text.
2. **Rule in wrong file** → check audience: orchestrator reads rules live via `@`; subagents only see baked content; context files are read by the orchestrator and curator, never browsed by a cycle role.
3. **Context file not read** → a developer can only Read it if the pitch's `scope:` named it, so the loop wrote it into `{"ev":"files_to_touch","role":"loop",...}`; check the pitch frontmatter and the cycle log's event, not the delegation prose.
4. **CLI flag wrong** → inspect harness builder output; verify `--tools` appended after prompt positional; `--json-schema` must be inline JSON.
5. **Hook not firing** → check `AGENT_TYPE` matcher in `settings.json`; check `is_outer_session()` guard; check `# HOOK-MANIFEST:` header declares correct signal.
6. **Project-specific rule in shared file** → move to `./context/<topic>.md`; update `PROJECT_CONTEXT.md` trigger row.
7. **Built-in subagent (`Plan`, `general-purpose`) spawned** → `operator-subagent-allowlist.sh` not installed; run `make install`.

## Where to Add a Constraint

| Constraint type                        | Layer             | File                                                                         |
| -------------------------------------- | ----------------- | ---------------------------------------------------------------------------- |
| Role behavior / coding pattern         | 1 — Shared rules  | OCG `shared/rules/<topic>.md`                                                |
| Role contract / gate / slice scope     | 2 — System prompt | OCG `shared/subagents/<role>.md.j2`                                          |
| Project-specific domain knowledge      | 3 — Context files | `./context/<topic>.md` + `PROJECT_CONTEXT.md` trigger row                    |
| Tool allowlist / model / schema        | 4 — CLI flags     | Your platform's harness builder (Example: `HarnessConfig.build/2`)           |
| Block a tool call / enforce at runtime | 5 — Hooks         | New hook in OCG `harnesses/claude/hooks/` + manifest header + `make install` |
| Reusable implementation pattern        | 6 — Recipes       | `./codegen/recipes/<slug>.md`                                                |

## Load Triggers (PROJECT_CONTEXT.md)

`PROJECT_CONTEXT.md` maps trigger keywords → context files. The orchestrator loads matching files on demand; a pitch author names them in `scope:` so the loop can grant the developer the same Reads. Add a row there when adding a new `./context/*.md` file.

Examples: trigger `"LLM"` → context/llm.md; trigger `"hooks"` → `context/hooks.md`; trigger `"provisioning"` → context/provisioning.md.

Recipes: same on-demand model — the developer reads a recipe when the task matches the pattern name. No trigger table needed; names are self-describing.

## Trigger Keywords

subagent wrong behavior, influence stack, rule violation, system prompt, Jinja includes, rules baking, delegation prompt, trigger table, recipe on-demand model
