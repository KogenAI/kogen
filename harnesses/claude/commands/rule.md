---
description: Add a new rule or principle with automatic orchestration/implementation separation
argument-hint: [rule description]
---

🚨 **STOP all pending work. Update rules FIRST. Only after rules are written and saved, resume any ongoing task.**

Extract lessons from conversation and add concise rules.

## Writing Guidelines

Read `~/Areas/Optimum/context/rules/STYLE_GUIDE.md` before writing. Key points:

- **Caveman ultra style** — rules read by agents, not humans. No preamble, no hedging. Fragments OK. Arrows for causality (X → Y).
- Max 10 lines per rule section
- Action-oriented — commands/searches first, not theory
- One concept per rule
- Bullets over paragraphs
- One example (bad/good pair), not multiple
- No emojis unless genuinely critical (max 2 per file) — rewrite unclear rules instead of adding 🚨

## Size Check (MANDATORY before writing)

After drafting: `echo "your section" | wc -l`. Section > 10 lines → compress. Code example > 6 lines → cut to minimal pattern.

## Layered Placement (MANDATORY — check in order)

1. **Shared rule** (`~/Areas/Optimum/context/rules/`) — universally true across ALL projects, baked into subagent system prompts, makes sense word-for-word in an unrelated project.
2. **Shared context** (`~/Areas/Optimum/context/`) — universal platform/tooling knowledge not in `rules/` (e.g., `claude-code-cli.md` for CLI semantics).
3. **Project `context/` file** (`./context/*.md`) — project-specific domain knowledge, infra pitfalls, per-tool config. Read on demand by planner. NOT baked into subagent prompts.
4. **`PROJECT_CONTEXT.md` / `CLAUDE.md`** — short operational facts, gate commands, port numbers.

Ask BEFORE placing:

- "Does a different project's planner/dev need this?" No → stay in `./context/`.
- "Which agent READS the target file?" Rule audience must match. ❌ Test-assertion guidance in `vite.md` (read by UI dev). ❌ Hook internals in `orchestrator.md`.
- "Is `make <target>` project-specific?" Yes → `./context/ci.md`, not shared rules.

Signs of leakage into shared rules: project names, repo paths, app-specific module/table/env-var names, infra/vendor specifics.

## Process

1. Extract lessons (errors, solutions, patterns)
2. Identify responsible role (decision tree below)
3. Write concisely — max 5-10 lines
4. Place in correct file

## Placement Decision Tree

1. **Whose behavior?** → role
2. **Stack-scoped?**
   - No → `roles/<role>.md`
   - Phoenix → step 3
   - Static → step 4
3. **Phoenix**:
   - Cross-role fact (idiom, Ecto, LiveView pattern) → `stacks/phoenix/_core.md`
   - Role-specific → `stacks/phoenix/<role>.md`
   - Testing → `stacks/phoenix/testing.md` (LiveView/browser → `testing-liveview.md`)
4. **Static**:
   - Role-specific (universal across substacks) → `stacks/static/<role>.md`
   - Substack-specific (HTML/Hugo/Vite) → `stacks/static/<substack>.md` (or `hugo-deep.md` for advanced Hugo)
   - Cross-substack (Tailwind/assets/JS) → `stacks/static/{tailwind,assets,js}.md`
5. **Cross-role primitive** (git read-only, etc.) → `shared/<concept>.md`
6. **Universal subagent rule** (output, bash, log) → `_core/<concept>.md`
7. **Build runtime** (result JSON) → `build-runtime/<concept>.md`

## Role Ownership Quick Reference

**Actor vs instructor** — before placing, ask: WHO ACTS on this behaviour vs WHO INSTRUCTS it.
Rule goes on the actor's file; instruction framing goes on the instructor's file.
If A tells B to do X → how to do X → B's file; how A communicates X → A's file.

❌ "orchestrator passes task summary to committer" in `committer.md` — committer doesn't decide how orchestrator communicates.
✅ Delegation framing → `orchestrator.md`; committer's file covers only what committer does with what it receives.

| Mistake                                                | Role         | File                                                                                                                              |
| ------------------------------------------------------ | ------------ | --------------------------------------------------------------------------------------------------------------------------------- |
| Orchestrator delegated wrong time / communicated badly | Orchestrator | `roles/orchestrator.md`                                                                                                           |
| Committer wrote wrong message / committed wrong files  | Committer    | `roles/committer.md`                                                                                                              |
| Developer wrote wrong code / skipped tests             | Developer    | `roles/developer.md` (universal) or `stacks/phoenix/developer.md` (Elixir style) or `stacks/phoenix/testing.md` (test discipline) |
| Gate misclassified verdict                             | Hook author  | `codegen/harnesses/claude/hooks/dev-gate.sh`                                                                                      |
| CR approved bad code / missed issues                   | CR           | `roles/reviewer.md` (universal) or `stacks/<stack>/reviewer.md` (stack-specific)                                                  |
| Any agent broke Elixir code style                      | Developer    | `stacks/phoenix/developer.md`                                                                                                     |
| Any agent broke CI                                     | Developer    | `stacks/phoenix/testing.md`                                                                                                       |

**Key principle**: if orchestrator made wrong call, rule goes on orchestrator — even if subagent executed the action.

**Split rule** (both orchestrator and subagent need it): one entry in each file. Each <10 lines.

## Classification

**Orchestration signals**: delegation timing, when-to-commit, gate sequencing, coordination, parallel execution.

**Subagent signals**: how to implement, code patterns, API usage, framework specifics, testing approaches, debugging, how to commit.

## File Placement Reference

Check `codegen/rules/INDEX.md` first to understand file boundaries.

### Core (`rules/_core/`) — loaded by every subagent

- `output-style.md` — caveman ultra
- `bash-discipline.md` — Bash + Read + token budget + ports
- `session-log.md` — file naming, skeleton, citations

### Shared (`rules/shared/`)

- `git-readonly.md` — read-only git ops, workspace, credentials

### Role (`rules/roles/`)

| File              | Scope                                                      |
| ----------------- | ---------------------------------------------------------- |
| `orchestrator.md` | Universal delegation/gates/commit timing/user comms/deploy |
| `planner.md`      | Universal — recipe/usage rules/plan structure              |
| `developer.md`    | Universal dev workflow — completion, pre-completion        |
| `reviewer.md`     | Universal 15-step review + ast-grep                        |
| `committer.md`    | Universal commit message, multi-repo                       |

### Stacks (`rules/stacks/`)

| File                          | Scope                                                            |
| ----------------------------- | ---------------------------------------------------------------- |
| `phoenix/_core.md`            | Cross-role idioms, Ecto, contexts, LiveView UI                   |
| `phoenix/orchestrator.md`     | Gate commands, INCONCLUSIVE, ext→agent, slice routing            |
| `phoenix/planner.md`          | Phoenix dep scan + OTP convention                                |
| `phoenix/developer.md`        | Pre-completion greps, mix workflow, hot reload, codegen patterns |
| `phoenix/reviewer.md`         | @spec/@type/~p/Gettext/github_workflows                          |
| `phoenix/committer.md`        | `.po/.pot` staging                                               |
| `phoenix/testing.md`          | CI/TDD/coverage/BDD/LLM partitions/backend                       |
| `phoenix/testing-liveview.md` | LiveView/HEEx/browser/SPA testing                                |
| `static/planner.md`           | Substack detection, tailwind detect                              |
| `static/developer.md`         | Output dir, build pipeline, npm, Tailwind v4 invariants          |
| `static/reviewer.md`          | Selector/a11y/asset/JS checks                                    |
| `static/html.md`              | Plain HTML stack                                                 |
| `static/hugo.md`              | Hugo quickref                                                    |
| `static/hugo-deep.md`         | Hugo deep (lazy load)                                            |
| `static/vite.md`              | Vite + React                                                     |
| `static/tailwind.md`          | Tailwind v4                                                      |
| `static/assets.md`            | Favicons, robots, og                                             |
| `static/js.md`                | Static-site JS                                                   |

### Build-Runtime (`rules/build-runtime/`)

- `result-json.md` — final JSON contract

## After Adding Rules

1. Update `INDEX.md` selectively — only on new file/category rename
2. Verify no duplication
3. Follow `STYLE_GUIDE.md`
