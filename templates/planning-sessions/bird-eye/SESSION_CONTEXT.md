# Bird-Eye Planning Session Context

## Session Details

- **Mode**: Bird-Eye Planning
- **Feature**: {{FEATURE_NAME}}
- **Model**: Claude Sonnet
- **Started**: {{SESSION_TIMESTAMP}}

## FORBIDDEN TOOLS

NEVER use:

- **EnterPlanMode**
- **ExitPlanMode**

OCG planning writes directly to `codegen/bird_eye_plans/{{FEATURE_NAME}}.md` using Write tool.

CORRECT plan location: `codegen/bird_eye_plans/{{FEATURE_NAME}}.md`
WRONG: `codegen/plans/`, `codegen/planning_sessions/`, `~/.claude/plans/`

---

## Load Rules BEFORE Anything Else

CANNOT proceed without completing these steps IN ORDER:

### Step 1: Load Core Planning Rules

```
Read file: ./codegen/rules/planning.md
Read file: ./codegen/rules/INDEX.md
```

Must have read BOTH before continuing.

### Step 2: Detect Project Type from PROJECT_CONTEXT.md

- Monorepo: has both `backend/` AND `mobile/`
- Backend-only: has `lib/` and `mix.exs` at root
- Flutter-only: has `lib/` and `pubspec.yaml` at root

This determines feature scope: "reactions" feature in monorepo needs backend API + mobile UI.

### VALIDATION: Prove You Loaded Rules

Before asking clarifying questions or starting plan:

1. List which rules you loaded (file paths)
2. State project type detected
3. Only THEN proceed

Example:

> "Loaded: `./codegen/rules/planning.md`, `./codegen/rules/INDEX.md`
>
> Project type: Monorepo (backend/ + mobile/)
>
> Clarifying questions..."

Why: even bird-eye plans need to follow planning rules.

---

## Planning Phase: Strategic Overview

PLANNING ONLY — NO IMPLEMENTATION. Read PROJECT_CONTEXT.md, analyze feature strategically, plan high-level approach, write plan file.

NEVER use Edit or MultiEdit on code files. NEVER look at code impl details.

### Resources

- `codegen/PROJECT_CONTEXT.md` — system, user workflows, existing features

### Output Expectations

MANDATORY plan location: `codegen/bird_eye_plans/{{FEATURE_NAME}}.md`

FORBIDDEN: `codegen/plans/`, `codegen/planning_sessions/`, `~/.claude/plans/`

Save to: [{{PLAN_OUTPUT_FILE}}]({{PLAN_OUTPUT_FILE}})

Plan size: 30-50 lines. Strategic overview, not details. Expanded in detailed planning phase.

Include:

- Feature description and user value proposition
- Integration analysis with existing features
- Parallel work recommendations (if applicable)
- Success criteria and risk assessment

### Next Steps

1. `ocg plan {{FEATURE_NAME}}` — detailed technical planning
2. `ocg new {{FEATURE_NAME}}` — create impl workspace
