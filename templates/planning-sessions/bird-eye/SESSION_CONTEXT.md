# Bird-Eye Planning Session Context

## Session Details

- **Mode**: Bird-Eye Planning
- **Feature**: {{FEATURE_NAME}}
- **Model**: Claude Sonnet
- **Started**: {{SESSION_TIMESTAMP}}

## 🚫 FORBIDDEN TOOLS - DO NOT USE

**CRITICAL**: These Claude Code built-in tools CONFLICT with OCG planning workflow:

- ❌ **EnterPlanMode** - NEVER use
- ❌ **ExitPlanMode** - NEVER use

OCG planning writes directly to `codegen/bird_eye_plans/{{FEATURE_NAME}}.md` using the **Write** tool. The built-in plan mode creates plans in `~/.claude/plans/` which is NOT how OCG works.

**🚨 CORRECT plan location:** `codegen/bird_eye_plans/{{FEATURE_NAME}}.md`
**❌ WRONG locations:** `codegen/plans/`, `codegen/planning_sessions/`, `~/.claude/plans/`, anywhere else

---

## 🛑 BLOCKING: Load Rules BEFORE Anything Else

**STOP! You CANNOT proceed without completing these steps IN ORDER:**

### Step 1: Load Core Planning Rules (REQUIRED)

```
Read file: ./codegen/rules/planning.md
Read file: ./codegen/rules/INDEX.md
```

**Checkpoint**: You must have read BOTH files above before continuing.

### Step 2: Detect Project Type from PROJECT_CONTEXT.md

Look for these indicators in PROJECT_CONTEXT.md:

- **Monorepo**: Has both `backend/` AND `mobile/` directories
- **Backend-only**: Has `lib/` and `mix.exs` at root
- **Flutter-only**: Has `lib/` and `pubspec.yaml` at root

**This determines feature scope**: A "reactions" feature in a monorepo needs backend API + mobile UI

### 🚨 VALIDATION: Prove You Loaded Rules

**Before asking clarifying questions or starting the plan, you MUST:**

1. **List which rules you loaded** (file paths)
2. **State the project type** you detected (monorepo/backend-only/etc.)
3. **Only THEN** proceed to ask clarifying questions

**Example correct response after loading rules:**

> "I've loaded the following rules:
>
> - `./codegen/rules/planning.md` (planning structure)
> - `./codegen/rules/INDEX.md` (rule discovery)
>
> Project type detected: **Monorepo** (backend/ + mobile/)
>
> Now let me ask some clarifying questions..."

**Why**: Even bird-eye plans need to follow planning rules. Loading rules ensures consistent plan structure.

## 🚨 MANDATORY: Clarifying Questions Before Planning

**CRITICAL**: After loading context, you MUST ask clarifying questions BEFORE creating any plan. Do NOT assume you understand requirements fully.

### Required Question Categories

Use the `AskUserQuestion` tool to ask about:

**1. Scope & Boundaries**

- What's explicitly IN scope vs OUT of scope?
- Are there related features that should wait for later?
- What's the minimum viable version vs nice-to-have?

**2. User & Business Context**

- Who are the primary users of this feature?
- What problem does this solve for them?
- Are there existing workarounds users currently use?

**3. Constraints & Preferences**

- Are there technology/vendor preferences or restrictions?
- Budget or timeline constraints?
- Integration requirements with external systems?

**4. Success Criteria**

- How will we know this feature is successful?
- What metrics matter?
- What would make this feature a failure?

### Example Questions to Ask

```
- "Should this feature work offline, or is network connectivity assumed?"
- "Do you want staging environment only first, or both staging and production?"
- "Are there manual steps you're willing to do, or should everything be automated?"
- "What existing accounts/services do you already have set up?"
- "What's the priority order if we can't do everything?"
```

### When to Skip Questions

Only skip if:

- User provided exhaustive requirements document
- This is a bug fix with clear reproduction steps
- User explicitly said "just do it, no questions"

**DEFAULT: ASK QUESTIONS FIRST**

---

## Planning Phase: Strategic Overview

You are in the first phase of feature development - **strategic planning**. This phase focuses on understanding the feature from a high-level, user-centric perspective.

### ⚠️ CRITICAL: PLANNING ONLY - NO IMPLEMENTATION

**DO NOT IMPLEMENT OR EDIT CODE** - This is a planning-only session. You should:

- ✅ **Read** PROJECT_CONTEXT.md to understand the system
- ✅ **Analyze** the feature from a strategic perspective
- ✅ **Plan** the high-level approach
- ✅ **Write plan file** to `{{PLAN_OUTPUT_FILE}}` using Write tool
- ❌ **NEVER use Edit or MultiEdit tools** on code files
- ❌ **NEVER modify code files** - only create the plan markdown file
- ❌ **NEVER look at code implementation details**
- ❌ **NEVER use EnterPlanMode or ExitPlanMode tools** - these are Claude Code built-in tools that conflict with OCG planning. Write plans directly to the output file instead.

**Your job is to create a strategic plan, not to implement it.**

### What You Should Focus On

**User Experience**

- How will users discover and interact with this feature?
- What problem does this solve for users?
- What is the user journey through this feature?

**Business Value**

- Why is this feature important?
- What stakeholder needs does it address?
- How does it align with project goals?

**System Integration**

- What existing features will this connect with?
- Are there opportunities for feature synergy?
- What are the key integration points?

**Work Organization**

- Can this feature be broken into independent parts?
- What work can happen in parallel?
- What are the critical path dependencies?

### Available Resources

**Project Context**

- Review `codegen/PROJECT_CONTEXT.md` to understand the system, user workflows, and existing features
- Current planning context is in `codegen/PLANNING_SESSION_CONTEXT.md` (this file)
- Main project instructions remain in `CLAUDE.md`

**Planning Guidelines**

- Keep plans high-level and user-focused
- Avoid technical implementation details
- Focus on "what" and "why", not "how"
- Consider both immediate and future implications

### Output Expectations

**🚨 MANDATORY Plan Location:**

```
codegen/bird_eye_plans/{{FEATURE_NAME}}.md
```

**❌ FORBIDDEN locations - NEVER write plans here:**

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

### 🚨 MANDATORY: Hallucination Check Before Finalizing

**CRITICAL**: Even for strategic plans, verify claims against actual project state and domain knowledge.

**REQUIRED CHECKS**:

1. **Project State Verification**:

   - Use Grep/Read to verify existing features you mention
   - Confirm user types/roles actually exist in the system
   - Check that workflows you reference are implemented
   - Verify integration points you describe exist

2. **Domain Knowledge**:

   - If mentioning industry standards, verify they're real
   - If referencing regulations/compliance, confirm requirements
   - If citing user research, ensure it's documented somewhere
   - If describing competitors, verify features actually exist

3. **Common Bird-Eye Hallucinations**:

   - ❌ Claiming features exist that don't ("integrate with existing X")
   - ❌ Inventing user types not in the system ("admin users can...")
   - ❌ Assuming workflows that aren't implemented ("after authentication flow...")
   - ❌ Wrong assumptions about existing architecture
   - ❌ Citing non-existent project patterns or conventions

4. **Verification Process**:

   ```bash
   # Verify features exist
   grep -r "FeatureName" lib/

   # Check user types
   grep -r "user_type" lib/*/accounts/

   # Confirm workflows
   grep -r "workflow_name" lib/
   ```

5. **Document What You Verified**:

   ```markdown
   ## Verification Notes

   - ✅ Confirmed "job posting" feature exists (lib/bemeda_personal/job_postings/)
   - ✅ Verified user types: job_seeker, employer (accounts/user.ex:45)
   - ✅ Checked authentication flow is implemented (user_session_controller.ex)
   - ⚠️ Note: "scheduling" mentioned but not yet implemented - flagged as future work
   ```

**WHEN TO CHECK**:

- ANY claim about existing features/functionality
- User types, roles, permissions
- Workflows and user journeys
- Integration points with other features
- Industry standards or regulations

**Example Catches**:

- Claiming "job seeker can schedule interviews" when scheduling doesn't exist
- Referencing "admin dashboard" that isn't built yet
- Assuming authentication pattern that project doesn't use
- Inventing user types not in the data model

**If you find mismatches**: Correct assumptions or mark clearly as "Future Work" vs "Current State".

### Next Steps

After completing bird-eye planning AND verification:

1. Use `ocg plan {{FEATURE_NAME}}` for detailed technical planning
2. Use `ocg new {{FEATURE_NAME}}` to create implementation workspace
3. Iterate between planning and implementation as needed

Remember: This is about strategic vision, not tactical execution. Keep your perspective at the "forest" level, not the "trees" level.
