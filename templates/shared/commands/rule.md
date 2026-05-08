---
description: Add a new rule or principle with automatic orchestration/implementation separation
argument-hint: [rule description]
---

🚨 **STOP all pending work. Update rules FIRST. Only after rules are written and saved, resume any ongoing task.**

Extract lessons from conversation and add concise rules.

## Writing Guidelines

Read `~/Areas/Optimum/context/rules/STYLE_GUIDE.md` before writing. Key points:

- **Caveman ultra style** — rules are read by agents, not humans. No preamble, no hedging, no pleasantries. Fragments OK. Arrows for causality (X → Y).
- Max 10 lines per rule section
- Action-oriented — commands/searches first, not theory
- One concept per rule
- Bullets over paragraphs
- One example (bad/good pair), not multiple
- No emojis unless genuinely critical (max 2 per file) — rewrite unclear rules instead of adding 🚨

## Size Check (MANDATORY before writing)

After drafting, count lines: `echo "your section" | wc -l`

- Section > 10 lines → compress before saving
- Code example > 6 lines → cut to minimal pattern, remove project-specific details
- "Would this example make sense in a different project?" → No = remove it, state rule in plain words

## Project-specific Content Check

Before adding to shared rule file: "Would this rule make sense word-for-word in a completely different project?"

- Yes → shared rule file
- No → `PROJECT_CONTEXT.md` or `CLAUDE.md` only

Signs of project-specific leakage (never in shared files):

- Project names, repo names, sibling repo paths
- Module names, table names, env var names specific to app
- Service names, infra details, vendor specifics

## Process

1. Extract lessons from conversation (errors, solutions, patterns)
2. Identify the responsible role (see below)
3. Write concisely — max 5-10 lines per rule
4. Place in the correct file for that role

## Find the Responsible Role

Before writing, identify whose job description covers the behaviour. Read role definitions from:

- `codegen/templates/shared/subagents/` — committer, planner, verification-engineer, code-reviewer, phoenix-developer, static-site-developer, data-layer-developer
- Project `CLAUDE.md` / `AGENTS.md` — orchestrator responsibilities

**Role ownership quick reference:**

| Who made the mistake                                  | Responsible role | Rule goes in                                 |
| ----------------------------------------------------- | ---------------- | -------------------------------------------- |
| Orchestrator delegated at wrong time                  | Orchestrator     | `rules/orchestration/delegation-patterns.md` |
| Orchestrator communicated badly                       | Orchestrator     | `rules/orchestration/user-communication.md`  |
| Committer wrote wrong message / committed wrong files | Committer        | `rules/subagents/git-commit-flow.md`         |
| Developer wrote wrong code / skipped tests            | Developer        | `rules/subagents/workflow.md` or `tdd.md`    |
| VE ran gates it shouldn't / missed failures           | VE               | `rules/subagents/verification-workflow.md`   |
| CR approved bad code / missed issues                  | CR               | `rules/subagents/code-review.md`             |
| Any agent broke Elixir code style                     | Developer        | `rules/subagents/elixir-code-generation.md`  |
| Any agent broke CI                                    | Developer/VE     | `rules/subagents/elixir-ci.md`               |

**Key principle**: if the orchestrator made the wrong call (e.g., delegated to committer too early), the rule goes on the **orchestrator** — even if a subagent executed the action. The subagent did its job correctly; the orchestrator invoked it at the wrong time.

**Split rule** (both orchestrator and subagent need it): write one entry in each file. Keep each under 10 lines.

## Classification

**Orchestration signals**: delegation timing, when-to-commit, gate sequencing, coordination, parallel execution, sequencing steps

**Subagent signals**: how to implement, code patterns, API usage, framework specifics, testing approaches, debugging, how to commit

## File Placement

Check `codegen/rules/INDEX.md` first to understand file boundaries.

- "Would this rule make sense in a different project?" → No = `CLAUDE.md` or `PROJECT_CONTEXT.md`, Yes = shared rule file

Each rule file has strict scope:

- `git-commit-flow.md` — how commits are structured; committer/dev execution details
- `delegation-patterns.md` — orchestrator decisions: when to commit, when to delegate, gate sequencing
- `workflow.md` — dev workflow and completion requirements, not git operations

If rule doesn't fit existing file: consider project-specific file, new focused rule file, or it's too narrow.

### Orchestration Rules (`rules/orchestration/`)

- `delegation-patterns.md` — subagent selection, coordination, gates, commit timing
- `user-communication.md` — communication style, autonomy, background task handling

### Impl Rules (`rules/subagents/`)

| File                      | Scope                                         |
| ------------------------- | --------------------------------------------- |
| git-commit-flow.md        | Commit structure, message format, git ops     |
| phoenix.md                | Phoenix/LiveView patterns, contexts, routing  |
| testing.md                | Testing patterns, CI authority, coverage      |
| testing-backend.md        | Backend testing (contexts, schemas, Req.Test) |
| elixir-code-generation.md | Code style, @spec, @impl, module organization |
| workflow.md               | Dev workflow, completion reqs                 |
| tdd.md                    | Red-green-refactor, pre-handoff checklist     |
| verification-workflow.md  | CI verification, reporting                    |
| code-review.md            | Quality analysis, systematic searches         |
| elixir-ci.md              | Credo, Dialyzer, CI pipeline                  |

## After Adding Rules

1. Update `INDEX.md` selectively — only when introducing a new rule file or renaming a category. Don't add impl details. INDEX.md is a map, not a changelog.
2. Verify no duplication with existing rules
3. Follow STYLE_GUIDE.md compression principles
