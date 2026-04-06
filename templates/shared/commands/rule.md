---
description: Add a new rule or principle with automatic orchestration/implementation separation
argument-hint: [rule description]
---

Extract lessons from conversation and add concise rules.

## Writing Guidelines

**Read `~/Areas/Optimum/context/rules/STYLE_GUIDE.md` before writing.** Key points:

- Max 10 lines per rule section
- Action-oriented — commands/searches first, not theory
- One concept per rule
- Bullet points over paragraphs
- One example (bad/good pair), not multiple

## Process

1. **Extract lessons** from conversation (errors, solutions, patterns)
2. **Write concisely** — max 5-10 lines per rule
3. **Classify each lesson**:
   - **Orchestration** → `./codegen/rules/orchestration/`
   - **Implementation** → `./codegen/rules/subagents/`
   - **Both** → Split into appropriate parts

## Classification

**Orchestration signals**: delegation, coordination, gate identification, parallel execution, resource management, sequencing

**Implementation signals**: code patterns, API usage, framework specifics, testing approaches, debugging techniques

## File Placement

**🔍 Check INDEX.md first** to understand file boundaries.

### Project-specific vs universal?

- "Would this rule make sense in a different project?" → **No** = put in `CLAUDE.md` or `PROJECT_CONTEXT.md`, **Yes** = shared rule file

**Each rule file has strict scope:**

- `git.md` — git operations only, not CI gates or workflow
- `workflow.md` — development cycle, not git operations
- `delegation-patterns.md` — subagent coordination, not implementation

If a rule doesn't fit an existing file: consider project-specific file, new focused rule file, or it's too narrow to be a rule.

### Orchestration Rules (`rules/orchestration/`)

- `delegation-patterns.md` — subagent selection, coordination, gates
- `user-communication.md` — communication style, autonomy

### Implementation Rules (`rules/subagents/`)

| File                      | Scope                                                  |
| ------------------------- | ------------------------------------------------------ |
| phoenix.md                | Phoenix/LiveView patterns, contexts, routing           |
| testing.md                | Testing patterns, CI authority, coverage               |
| testing-backend.md        | Backend-specific testing (contexts, schemas, Req.Test) |
| elixir-code-generation.md | Code style, @spec, @impl, module organization          |
| workflow.md               | Development workflow, completion requirements          |
| tdd.md                    | Red-green-refactor, pre-handoff checklist              |
| verification-workflow.md  | CI verification, reporting                             |
| code-review.md            | Quality analysis, systematic searches                  |
| elixir-ci.md              | Credo, Dialyzer, CI pipeline                           |

## After Adding Rules

1. Update `./codegen/rules/INDEX.md` keyword index
2. Verify no duplication with existing rules
3. Follow STYLE_GUIDE.md compression principles
