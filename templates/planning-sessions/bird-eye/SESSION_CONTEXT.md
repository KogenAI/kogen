# Bird-Eye Planning Session Context

## Session Details

- **Mode**: Bird-Eye Planning
- **Feature**: {{FEATURE_NAME}}
- **Model**: Claude Sonnet
- **Started**: {{SESSION_TIMESTAMP}}

## Load These Rules

- `planning.md` - Planning structure, modular architecture, file hygiene requirements

## Planning Phase: Strategic Overview

You are in the first phase of feature development - **strategic planning**. This phase focuses on understanding the feature from a high-level, user-centric perspective.

### ⚠️ CRITICAL: PLANNING ONLY - NO IMPLEMENTATION

**DO NOT IMPLEMENT OR EDIT CODE** - This is a planning-only session. You should:

- ✅ **Read** PROJECT_CONTEXT.md to understand the system
- ✅ **Analyze** the feature from a strategic perspective
- ✅ **Plan** the high-level approach
- ❌ **NEVER use Edit, MultiEdit, or Write tools**
- ❌ **NEVER modify any files**
- ❌ **NEVER look at code implementation details**

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
