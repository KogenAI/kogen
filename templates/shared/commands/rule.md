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

## Size Check (MANDATORY before writing)

After drafting, count lines: `echo "your section" | wc -l`

- Section > 10 lines → compress before saving
- Code example > 6 lines → cut to minimal pattern, remove project-specific details
- "Would this example make sense in a different project?" → No = remove it, state the rule in plain words

## Project-specific Content Check

Before adding any identifier (function name, library name, service name) to a shared rule file, ask:

- Is this universal Elixir/Phoenix/Oban behaviour? → shared rule file
- Is this specific to this project's stack? → `PROJECT_CONTEXT.md` or `CLAUDE.md` only

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

1. **Update INDEX.md selectively** — only when introducing a new rule file or renaming a category. Don't add implementation details (e.g., "Oban worker return values"). INDEX.md is a map, not a changelog. Keywords should name primary domains; sub-topics belong inside the rule file.
2. Verify no duplication with existing rules
3. Follow STYLE_GUIDE.md compression principles
