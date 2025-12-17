# Bird-Eye Planning Session Context

## Session Details

- **Mode**: Bird-Eye Planning
- **Feature**: {{FEATURE_NAME}}
- **Model**: Claude Sonnet
- **Started**: {{SESSION_TIMESTAMP}}

## FORBIDDEN TOOLS - DO NOT USE

**CRITICAL**: These Claude Code built-in tools CONFLICT with OCG planning workflow:

- **EnterPlanMode** - NEVER use
- **ExitPlanMode** - NEVER use

OCG planning writes directly to `codegen/bird_eye_plans/{{FEATURE_NAME}}.md` using the **Write** tool. The built-in plan mode creates plans in `~/.claude/plans/` which is NOT how OCG works.

**CORRECT plan location:** `codegen/bird_eye_plans/{{FEATURE_NAME}}.md`
**WRONG locations:** `codegen/plans/`, `codegen/planning_sessions/`, `~/.claude/plans/`, anywhere else

---

## BLOCKING: Load Rules BEFORE Anything Else

**STOP! You CANNOT proceed without completing these steps IN ORDER:**

### Step 1: Load Core Planning Rules (REQUIRED)

```
Read file: ./codegen/rules/planning.md
Read file: ./codegen/rules/planning/bird-eye.md
Read file: ./codegen/rules/INDEX.md
```

**Checkpoint**: You must have read ALL THREE files above before continuing.

### Step 2: Detect Project Type from PROJECT_CONTEXT.md

Look for these indicators in PROJECT_CONTEXT.md:

- **Monorepo**: Has both `backend/` AND `mobile/` directories
- **Backend-only**: Has `lib/` and `mix.exs` at root
- **Flutter-only**: Has `lib/` and `pubspec.yaml` at root

**This determines feature scope**: A "reactions" feature in a monorepo needs backend API + mobile UI

### VALIDATION: Prove You Loaded Rules

**Before asking clarifying questions or starting the plan, you MUST:**

1. **List which rules you loaded** (file paths)
2. **State the project type** you detected (monorepo/backend-only/etc.)
3. **Only THEN** proceed to ask clarifying questions

**Example correct response after loading rules:**

> "I've loaded the following rules:
>
> - `./codegen/rules/planning.md` (shared planning rules)
> - `./codegen/rules/planning/bird-eye.md` (bird-eye specific rules)
> - `./codegen/rules/INDEX.md` (rule discovery)
>
> Project type detected: **Monorepo** (backend/ + mobile/)
>
> Now let me ask some clarifying questions..."

**Why**: Even bird-eye plans need to follow planning rules. Loading rules ensures consistent plan structure.

---

## Planning Phase: Strategic Overview

You are in the first phase of feature development - **strategic planning**. This phase focuses on understanding the feature from a high-level, user-centric perspective.

### CRITICAL: PLANNING ONLY - NO IMPLEMENTATION

**DO NOT IMPLEMENT OR EDIT CODE** - This is a planning-only session. You should:

- **Read** PROJECT_CONTEXT.md to understand the system
- **Analyze** the feature from a strategic perspective
- **Plan** the high-level approach
- **Write plan file** to `{{PLAN_OUTPUT_FILE}}` using Write tool
- **NEVER use Edit or MultiEdit tools** on code files
- **NEVER modify code files** - only create the plan markdown file
- \*\*NEVER look at code implementation details
- **NEVER use EnterPlanMode or ExitPlanMode tools** - these are Claude Code built-in tools that conflict with OCG planning

**Your job is to create a strategic plan, not to implement it.**

### Available Resources

**Project Context**

- Review `codegen/PROJECT_CONTEXT.md` to understand the system, user workflows, and existing features
- Current planning context is in `codegen/PLANNING_SESSION_CONTEXT.md` (this file)
- Main project instructions remain in `CLAUDE.md`

### Output Expectations

**MANDATORY Plan Location:**

```
codegen/bird_eye_plans/{{FEATURE_NAME}}.md
```

**FORBIDDEN locations - NEVER write plans here:**

- `codegen/plans/` - WRONG (this is for detailed plans)
- `codegen/planning_sessions/` - WRONG
- `~/.claude/plans/` - WRONG (Claude Code built-in, not OCG)
- Any other location - WRONG

Save your final plan to: [{{PLAN_OUTPUT_FILE}}]({{PLAN_OUTPUT_FILE}})

**Plan Size Guidelines:**

- Target: 30-50 lines for bird-eye plans
- Focus on strategic overview, not details
- Use clear, concise language
- This plan will be expanded in the detailed planning phase

Include in your plan:

- Clear feature description and user value proposition
- Integration analysis with existing features
- Parallel work recommendations (if applicable)
- Success criteria and risk assessment

### Next Steps

After completing bird-eye planning AND verification:

1. Use `ocg plan {{FEATURE_NAME}}` for detailed technical planning
2. Use `ocg new {{FEATURE_NAME}}` to create implementation workspace
3. Iterate between planning and implementation as needed

Remember: This is about strategic vision, not tactical execution. Keep your perspective at the "forest" level, not the "trees" level.
