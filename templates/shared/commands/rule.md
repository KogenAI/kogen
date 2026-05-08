---
description: Add a new rule or principle with automatic orchestration/implementation separation
argument-hint: [rule description]
---

🚨 **STOP all pending work. Update rules FIRST. Only after rules are written and saved, resume any ongoing task.**

Extract lessons from conversation and add concise rules.

## Writing Guidelines

Read `~/Areas/Optimum/context/rules/STYLE_GUIDE.md` before writing. Key points:

- Max 10 lines per rule section
- Action-oriented — commands/searches first, not theory
- One concept per rule
- Bullets over paragraphs
- One example (bad/good pair), not multiple

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
2. Write concisely — max 5-10 lines per rule
3. Classify each lesson:
   - Orchestration → `./codegen/rules/orchestration/`
   - Impl → `./codegen/rules/subagents/`
   - Both → split into appropriate parts

## Classification

**Orchestration signals**: delegation, coordination, gate identification, parallel execution, resource management, sequencing

**Impl signals**: code patterns, API usage, framework specifics, testing approaches, debugging techniques

## File Placement

Check INDEX.md first to understand file boundaries.

- "Would this rule make sense in a different project?" → No = `CLAUDE.md` or `PROJECT_CONTEXT.md`, Yes = shared rule file

Each rule file has strict scope:

- `git.md` — git operations only, not CI gates or workflow
- `workflow.md` — dev cycle, not git operations
- `delegation-patterns.md` — subagent coordination, not impl

If rule doesn't fit existing file: consider project-specific file, new focused rule file, or it's too narrow.

### Orchestration Rules (`rules/orchestration/`)

- `delegation-patterns.md` — subagent selection, coordination, gates
- `user-communication.md` — communication style, autonomy

### Impl Rules (`rules/subagents/`)

| File                      | Scope                                         |
| ------------------------- | --------------------------------------------- |
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

1. Update INDEX.md selectively — only when introducing new rule file or renaming category. Don't add impl details. INDEX.md is a map, not changelog.
2. Verify no duplication with existing rules
3. Follow STYLE_GUIDE.md compression principles
