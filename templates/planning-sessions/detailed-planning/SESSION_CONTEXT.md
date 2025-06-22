# Detailed Planning Session Context

## Session Details

- **Mode**: Detailed Planning
- **Feature**: {{FEATURE_NAME}}
- **Model**: Claude Sonnet
- **Started**: {{SESSION_TIMESTAMP}}

## Planning Phase: Technical Implementation

You are in the technical planning phase - **detailed implementation planning**. This phase focuses on creating comprehensive technical plans ready for implementation.

### ⚠️ CRITICAL: PLANNING ONLY - NO IMPLEMENTATION

**DO NOT IMPLEMENT OR EDIT CODE** - This is a planning-only session. You should:

- ✅ **Analyze** existing code to understand patterns
- ✅ **Read** files to understand the current implementation
- ✅ **Plan** the technical approach in detail
- ❌ **NEVER use Edit, MultiEdit, or Write tools**
- ❌ **NEVER modify any files**
- ❌ **NEVER implement the actual solution**

**Your job is to create a detailed plan, not to implement it.**

### What You Should Focus On

**Technical Architecture**

- How will this feature be technically implemented?
- What are the key components and their interactions?
- How does this fit with existing system architecture?

**Code Integration Analysis**

- What existing code can be reused or extended?
- What are the integration points with current features?
- What patterns and conventions should be followed?

**Implementation Details**

- What database changes are needed?
- What API endpoints need to be created/modified?
- What frontend components are required?
- What background jobs or processes are needed?

**Quality Considerations**

- What tests need to be written?
- What are the security implications?
- What are the performance considerations?
- What error handling is required?

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

**Planning Guidelines**

- Be thorough and specific in technical details
- Plan for code reuse and pattern consistency
- Consider both immediate implementation and future extensibility
- Plan comprehensive test coverage from the start

### Output Expectations

Save your final plan to: [{{PLAN_OUTPUT_FILE}}]({{PLAN_OUTPUT_FILE}})

Include in your plan:

- Specific technical implementation approach
- Database schema changes and migration plans
- API endpoint specifications
- Component and module structure
- Comprehensive test plan
- Step-by-step implementation sequence
- Dependencies and prerequisites
- Performance and security considerations

### Implementation Readiness

Your plan should be detailed enough that an engineer can:

- Understand exactly what needs to be built
- Follow a clear implementation sequence
- Know what tests to write
- Understand integration requirements
- Identify potential risks and challenges

### Next Steps

After completing detailed planning:

1. Use `ocg new {{FEATURE_NAME}}` to create implementation workspace
2. The workspace will include your plan as `PLAN.md`
3. Implementation can follow your detailed plan step-by-step
4. Update `PROJECT_CONTEXT.md` after implementation with learnings

Remember: This is about technical precision and implementation readiness. The better your plan, the smoother the implementation will be.
