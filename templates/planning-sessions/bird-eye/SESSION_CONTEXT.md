# Bird-Eye Planning Session Context

## Session Details
- **Mode**: Bird-Eye Planning
- **Feature**: {{FEATURE_NAME}}
- **Model**: Claude Sonnet
- **Started**: {{SESSION_TIMESTAMP}}

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

Include in your plan:
- Clear feature description and user value proposition
- Integration analysis with existing features
- Parallel work recommendations (if applicable)
- Success criteria and risk assessment

### Next Steps

After completing bird-eye planning:
1. Use `ocg plan {{FEATURE_NAME}}` for detailed technical planning
2. Use `ocg new {{FEATURE_NAME}}` to create implementation workspace
3. Iterate between planning and implementation as needed

Remember: This is about strategic vision, not tactical execution. Keep your perspective at the "forest" level, not the "trees" level.
