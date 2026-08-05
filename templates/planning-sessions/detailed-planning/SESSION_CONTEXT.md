# Detailed Planning Session Context

## Session Details

- **Mode**: Detailed Planning
- **Feature**: {{FEATURE_NAME}}
- **Model**: Claude Sonnet
- **Started**: {{SESSION_TIMESTAMP}}

## FORBIDDEN TOOLS

NEVER use:

- **EnterPlanMode**
- **ExitPlanMode**

OCG planning writes directly to `codegen/plans/{{FEATURE_NAME}}/` using Write tool. Built-in plan mode creates plans in `~/.claude/plans/` — wrong location.

CORRECT plan location: `codegen/plans/{{FEATURE_NAME}}/overview.md`

---

## Load Rules BEFORE Anything Else

CANNOT proceed without completing these steps IN ORDER:

### Step 1: Load Core Planning Rules

```
Read file: ./codegen/rules/planning.md
Read file: ./codegen/rules/planning/detailed.md
Read file: ./codegen/rules/INDEX.md
```

Must have read ALL THREE before continuing.

### Step 2: Detect Project Type from PROJECT_CONTEXT.md

- Monorepo: has both `backend/` AND `mobile/`
- Backend-only: has `lib/` and `mix.exs` at root
- Flutter-only: has `lib/` and `pubspec.yaml` at root

### Step 3: Load Domain Rules

For Monorepo or Phoenix/Elixir:

```
Read file: ./codegen/rules/stacks/phoenix/_core.md
Read file: ./codegen/rules/stacks/phoenix/developer.md
```

LiveView UI patterns live in `phoenix/_core.md`.

### Step 4: Load Additional Rules Based on Feature

- Figma design impl → `rules/subagents/ui-implementation.md` (pixel-perfect from Figma)
- Testing features → `rules/stacks/phoenix/testing.md`

### VALIDATION: Prove You Loaded Rules

Before saying "ready for feature description":

1. List which rules you loaded (file paths)
2. State project type detected
3. Only THEN say you're ready

Example correct response:

> "Loaded: `./codegen/rules/planning.md`, `./codegen/rules/planning/detailed.md`, `./codegen/rules/INDEX.md`, `./codegen/rules/stacks/phoenix/_core.md`, `./codegen/rules/stacks/phoenix/developer.md`
>
> Project type: Phoenix/Elixir (lib/ and mix.exs at root)
>
> Ready for feature description."

Why: plans with specific code must follow domain patterns. Loading rules prevents bad patterns that won't get fixed during impl.

---

## Figma Extraction (If Figma URLs Provided)

If user provides Figma URLs, follow extraction process in `./codegen/rules/planning/detailed.md`:

1. Phase 1: Extract Specs from parent frames
2. Phase 2: Parse specs to find individual screen node IDs
3. Phase 3: Create node-ids.txt with actual Figma frame names
4. Phase 4: Extract individual screenshots
5. Phase 4b: MANDATORY screenshot content verification
6. Phase 5: Generate SCREENS.md index

FORBIDDEN after Figma extraction: questions about things visible in screenshots.
ALLOWED: questions about backend behavior, permissions, real-time updates.

---

## Planning Phase: Technical Implementation

PLANNING ONLY — NO IMPLEMENTATION. Analyze existing code, read files, plan technical approach, write plan files.

NEVER:

- Use Edit or MultiEdit tools on code files
- Modify code files
- Use EnterPlanMode or ExitPlanMode

### Resources

- Full read access to codebase — use Grep, Glob, Read, Task for analysis
- `codegen/PROJECT_CONTEXT.md` — system architecture, patterns, conventions

### Output Expectations

MANDATORY plan location: `codegen/plans/{{FEATURE_NAME}}/overview.md`

FORBIDDEN locations:

- `codegen/planning_sessions/plans/`
- `~/.claude/plans/`
- Anywhere else

Modular plan structure:

```
codegen/plans/{{FEATURE_NAME}}/
├── overview.md          # 50-100 lines: goals, architecture, step sequence
└── steps/
    ├── step-01-setup.md    # 150-250 lines
    ├── step-02-core.md     # 150-250 lines
    ├── step-03-ui.md       # 150-250 lines
    └── step-04-tests.md    # 150-250 lines
```

Step file naming: `step-##-descriptor.md` (e.g., `step-01-setup.md`). Zero-padded numbers, kebab-case descriptors.

During impl, only overview + current step loaded (~200-350 lines total).

### Impl Readiness

Plan must enable an engineer to:

- Understand exactly what needs to be built
- Follow clear impl sequence
- Know what tests to write
- Understand integration reqs
- Identify risks and challenges

### Hallucination Check Before Finalizing

After writing plan, verify against official docs AND Figma screenshots (if applicable). See `./codegen/rules/planning/detailed.md` for:

- Figma feature hallucination check process
- Verification checklist
- Common hallucination patterns to avoid

### Next Steps

1. Use `ocg new {{FEATURE_NAME}}` to create impl workspace
2. Orchestrator delegates ALL step reqs to appropriate subagents
3. Every step must be complete and self-contained — orchestrator cannot skip parts
4. TDD approach: phoenix-dev implements code+tests, then VE checks
5. Update `PROJECT_CONTEXT.md` after impl
