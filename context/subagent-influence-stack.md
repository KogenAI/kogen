# LLM Influence Stack

> Where to look when an LLM subagent does the wrong thing, and where to add a constraint so it doesn't happen again.

## Layer Map

| #   | Layer                  | Where it lives                   | Who reads it                                   | When it applies                           |
| --- | ---------------------- | -------------------------------- | ---------------------------------------------- | ----------------------------------------- |
| 1   | Shared rules           | OCG shared rules dir             | Subagents (baked), orchestrator (live via `@`) | Every invocation                          |
| 2   | Subagent system prompt | `~/.claude/agents/<role>.md`     | Subagent on spawn                              | Every subagent invocation                 |
| 3   | Project context files  | `./context/*.md`                 | Planner on demand                              | When planner reads + passes excerpts      |
| 4   | Runtime CLI flags      | Built by your platform's harness | Claude Code CLI                                | Per-invocation; append-only               |
| 5   | Hooks                  | `~/.claude/hooks/*.sh`           | Claude Code runtime                            | On tool use / subagent stop / stop events |
| 6   | Recipes                | `./codegen/recipes/`             | Planner on demand                              | When known pattern matches task           |

## Layer 1 — Shared Rules (baked into system prompt)

Source: OCG `shared/rules/` directory (canonical root differs across machines AND OSes — Linux servers + the Hetzner dashboard box, and operator Macs — so it is never hardcoded; e.g. `~/apps/codegen/shared/rules/` on the box vs `~/Areas/Optimum/codegen/shared/rules/` on a Mac. See `context/deployment-topology.md`). Baked into subagent prompts via Jinja `{% include %}` in templates under `shared/subagents/`. `make install` regenerates `~/.claude/agents/*.md` and commits to each project.

Orchestrator loads rules LIVE at session start via `@codegen/rules/...` auto-includes. Subagents only see what was baked at last `make install`. Diverge silently if `make install` skipped after edit.

Scope: editing any file under `shared/rules/` or `codegen/templates/` → MUST run `make install`. (`codegen/rules/` is a symlink to `shared/rules/` post-install; edit `shared/rules/` directly, not through the symlink.)

## Layer 2 — Subagent System Prompt

File: `~/.claude/agents/<role>.md`. Generated from `<role>.md.j2` template. Contains baked rules + role contract (slice scope, gate command, output style). Subagent reads this on every spawn — can't be changed mid-session without `make install` + re-spawn.

To inspect what a subagent actually has: Read tool on `~/.claude/agents/<role>.md` (Example: `~/.claude/agents/developer-phoenix-backend.md`).

**Orchestrator prompt assembly** — Special case: the build orchestrator prompt is assembled from `harnesses/<harness>/tools-header/build.txt` ONLY. The `tools-header/build.txt` file contains all cycle statements (reviewer → curator → committer sequencing) and the step-0 session-log ritual (fetch-then-Write with canonical name `YYYYMMDD_HHMMSS_slug_session.md`). Edits to `shared/rules/roles/orchestrator.md` do NOT propagate to orchestrator invocations; `build.txt` is the canonical source. Edits to `build.txt` are NOT templated (unlike other agent prompts) — they are inlined directly by `codegen-build` at launch. After editing `build.txt`, run `make install` to validate syntax, then re-invoke `codegen-build`. The step-0 ritual is enforced at Layer 5 (Write-time allowlist guard `orchestrator-session-log-name-guard`) so ritual violations are impossible.

## Layer 3 — Project Context Files

Files: `./context/*.md`. NOT auto-loaded into subagent prompts. Planner reads on demand based on trigger keywords in `PROJECT_CONTEXT.md`, then passes relevant excerpts in delegation prompt. Audience = planner + orchestrator — dev subagents only see what planner forwards.

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

Key enforcement hooks (Examples): stack-specific dev-gate (`phoenix-dev-gate.sh`), `orchestrator-no-source-edit.sh` (write surface), `dev-no-ci.sh` (blocks gate commands + bare test runners), `pre-commit-guard.sh` (blocks git commit for non-committer), `operator-subagent-allowlist.sh` (blocks `Plan`/`general-purpose` built-ins).

## Layer 6 — Recipes

Files: `./codegen/recipes/`. Read ON DEMAND by planner when a known pattern matches. Not auto-loaded. Named in planner delegation prompt for dev to read on demand.

---

## Debugging Checklist

Work top-down when subagent does wrong thing:

1. **Rule exists but subagent ignored it** → was `make install` run after editing? Check `~/.claude/agents/<role>.md` for the rule text.
2. **Rule in wrong file** → check audience: orchestrator reads rules live via `@`; subagents only see baked content; planner reads context files.
3. **Context file not read** → planner must explicitly load it; check delegation prompt for the context reference.
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

`PROJECT_CONTEXT.md` maps trigger keywords → context files. Planner loads matching files on demand. Add a row there when adding a new `./context/*.md` file.

Examples: trigger `"LLM"` → `context/llm.md`; trigger `"hooks"` → `context/hooks.md`; trigger `"provisioning"` → `context/provisioning.md`.

Recipes: same on-demand model — planner reads recipe when task matches the pattern name. No trigger table needed; names are self-describing.
