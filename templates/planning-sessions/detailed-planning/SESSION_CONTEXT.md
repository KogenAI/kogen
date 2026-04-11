# Detailed Planning Session Context

## Session Details

- **Mode**: Detailed Planning
- **Feature**: {{FEATURE_NAME}}
- **Model**: Claude Sonnet
- **Started**: {{SESSION_TIMESTAMP}}

## FORBIDDEN TOOLS - DO NOT USE

**CRITICAL**: These Claude Code built-in tools CONFLICT with OCG planning workflow:

- **EnterPlanMode** - NEVER use
- **ExitPlanMode** - NEVER use

OCG planning writes directly to `codegen/plans/{{FEATURE_NAME}}/` using the **Write** tool. The built-in plan mode creates plans in `~/.claude/plans/` which is NOT how OCG works.

**CORRECT plan location:** `codegen/plans/{{FEATURE_NAME}}/overview.md`
**WRONG locations:** `codegen/planning_sessions/plans/`, `~/.claude/plans/`, anywhere else

---

## BLOCKING: Load Rules BEFORE Anything Else

**STOP! You CANNOT proceed without completing these steps IN ORDER:**

### Step 1: Load Core Planning Rules (REQUIRED)

```
Read file: ./codegen/rules/planning.md
Read file: ./codegen/rules/planning/detailed.md
Read file: ./codegen/rules/INDEX.md
```

**Checkpoint**: You must have read ALL THREE files above before continuing.

### Step 2: Detect Project Type from PROJECT_CONTEXT.md

Look for these indicators in PROJECT_CONTEXT.md:

- **Monorepo**: Has both `backend/` AND `mobile/` directories
- **Backend-only**: Has `lib/` and `mix.exs` at root
- **Flutter-only**: Has `lib/` and `pubspec.yaml` at root

### Step 3: Load Domain Rules Based on Project Type

**For Monorepo (backend + mobile)**:

```
Read file: ./codegen/rules/subagents/phoenix.md
Read file: ./codegen/rules/subagents/phoenix-ui.md
Read file: ./codegen/rules/subagents/elixir-code-generation.md
```

**For Phoenix/Elixir (includes LiveView UI)**:

```
Read file: ./codegen/rules/subagents/phoenix.md
Read file: ./codegen/rules/subagents/phoenix-ui.md
Read file: ./codegen/rules/subagents/elixir-code-generation.md
```

**Note**: Phoenix projects ALWAYS include `phoenix-ui.md` because Phoenix LiveView is inherently a UI framework.

### Step 4: Load Additional Domain Rules Based on Feature

Based on what the user describes as the feature, also load:

- **Figma design implementation**: `rules/subagents/ui-implementation.md` (pixel-perfect from Figma)
- **Testing features**: `rules/subagents/testing.md`

**Note**: `phoenix-ui.md` (LiveView components, forms, JS hooks) is already loaded in Step 3 for Phoenix projects. `ui-implementation.md` is for Figma-to-code pixel-perfect workflows.

### VALIDATION: Prove You Loaded Rules

**Before saying "ready for feature description", you MUST:**

1. **List which rules you loaded** (file paths)
2. **State the project type** you detected (monorepo/backend-only/etc.)
3. **Only THEN** say you're ready for the feature description

**Example correct response after loading rules:**

> "I've loaded the following rules:
>
> - `./codegen/rules/planning.md` (shared planning rules)
> - `./codegen/rules/planning/detailed.md` (detailed planning rules)
> - `./codegen/rules/INDEX.md` (rule discovery)
> - `./codegen/rules/subagents/phoenix.md` (Phoenix patterns)
> - `./codegen/rules/subagents/phoenix-ui.md` (LiveView UI patterns)
> - `./codegen/rules/subagents/elixir-code-generation.md` (Elixir patterns)

> Project type detected: **Phoenix/Elixir** (has lib/ and mix.exs at root)
>
> I'm ready for you to describe the feature."

**Why**: Plans with specific code must follow domain patterns. Loading appropriate rules prevents bad code patterns that won't get fixed during implementation.

---

## Figma Extraction (If Figma URLs Provided)

**CRITICAL**: If user provides Figma URLs, follow the extraction process in `./codegen/rules/planning/detailed.md`:

1. Phase 1: Extract Specs from parent frames
2. Phase 2: Parse specs to find individual screen node IDs
3. Phase 3: Create node-ids.txt with actual Figma frame names
4. Phase 4: Extract individual screenshots
5. Phase 4b: MANDATORY screenshot content verification
6. Phase 5: Generate SCREENS.md index

**FORBIDDEN after Figma extraction**: Questions about things visible in screenshots

**ALLOWED after Figma extraction**: Questions about backend behavior, permissions, real-time updates

---

## Planning Phase: Technical Implementation

You are in the technical planning phase - **detailed implementation planning**. This phase focuses on creating comprehensive technical plans ready for implementation.

### CRITICAL: PLANNING ONLY - NO IMPLEMENTATION

**DO NOT IMPLEMENT OR EDIT CODE** - This is a planning-only session. You should:

- **Analyze** existing code to understand patterns
- **Read** files to understand the current implementation
- **Plan** the technical approach in detail
- **Write plan files** to `codegen/plans/{{FEATURE_NAME}}/` using Write tool
- **NEVER use Edit or MultiEdit tools** on code files
- **NEVER modify code files** - only create/update plan markdown files
- **NEVER implement the actual solution**
- **NEVER use EnterPlanMode or ExitPlanMode tools** - these are Claude Code built-in tools that conflict with OCG planning

**Your job is to create a detailed plan, not to implement it.**

### Available Resources

**Codebase Analysis**

- Full read access to the entire codebase
- Use Grep, Glob, Read, and Task tools for thorough analysis
- Look for similar existing implementations to learn from
- Understand current patterns and architectural decisions

**Project Context**

- Review `codegen/PROJECT_CONTEXT.md` to understand the system architecture, patterns, and conventions
- Current planning context is in `codegen/PLANNING_SESSION_CONTEXT.md` (this file)
- Main project instructions remain in `CLAUDE.md`

### Output Expectations

**MANDATORY Plan Location:**

```
codegen/plans/{{FEATURE_NAME}}/overview.md
```

**FORBIDDEN locations - NEVER write plans here:**

- `codegen/planning_sessions/plans/` - WRONG
- `codegen/planning_sessions/` - WRONG
- `~/.claude/plans/` - WRONG (Claude Code built-in, not OCG)
- Any other location - WRONG

**Create Modular Plan Structure:**

```
codegen/plans/{{FEATURE_NAME}}/
├── overview.md          # Main plan (50-100 lines): goals, architecture, step sequence
└── steps/
    ├── step-01-setup.md    # Setup and infrastructure (150-250 lines)
    ├── step-02-core.md     # Core implementation (150-250 lines)
    ├── step-03-ui.md       # UI components (150-250 lines)
    └── step-04-tests.md    # Testing implementation (150-250 lines)
```

**Step File Naming Convention:**

- Use format: `step-##-descriptor.md` (e.g., `step-01-setup.md`, `step-02-core.md`)
- Zero-padded numbers for proper sorting
- Kebab-case descriptors (lowercase, hyphens, no spaces)
- Keep descriptors short and clear

**Plan Size Guidelines:**

- **Overview**: 50-100 lines covering goals, architecture, step sequence
- **Step files**: 150-250 lines each with detailed implementation for that step
- Focus on actionable steps, not verbose explanations
- Remember: During implementation, only overview + current step will be loaded (~200-350 lines total)

### Implementation Readiness

Your plan should be detailed enough that an engineer can:

- Understand exactly what needs to be built
- Follow a clear implementation sequence
- Know what tests to write
- Understand integration requirements
- Identify potential risks and challenges

### MANDATORY: Hallucination Check Before Finalizing

After writing your plan, verify it against official documentation AND Figma screenshots (if applicable).

See `./codegen/rules/planning/detailed.md` for:

- Figma feature hallucination check process
- Verification checklist for each planned step
- Common hallucination patterns to avoid

### Next Steps

After completing detailed planning AND hallucination check:

1. Use `ocg new {{FEATURE_NAME}}` to create implementation workspace
2. The workspace will include your modular plan structure
3. **Orchestrator implements using delegation patterns**: Main agent delegates ALL step requirements to appropriate subagents
4. **Step completeness**: Every requirement in each step (code, tests, deployment config) must be delegated
5. Update `PROJECT_CONTEXT.md` after implementation with learnings

**CRITICAL: Plan → Implementation Alignment**

- **Your plans will be executed by orchestrator agents** using delegation patterns
- **Each step must be complete and self-contained** - orchestrator cannot skip parts
- **Include ALL requirements per step**: If step includes deployment config, mark clearly for devops-manager delegation
- **TDD approach aligns with orchestrator workflow**: phoenix-developer implements code+tests, then verification-engineer checks

Remember: This is about technical precision and implementation readiness. The better your plan, the smoother the orchestrated implementation will be.
