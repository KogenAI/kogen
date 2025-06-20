# CLAUDE.md

This file provides guidance to Claude Code when working in detailed planning mode.

## Detailed Planning Mode

You are in **detailed planning mode** - focus on technical implementation planning with high detail and precision.

### Your Role
Create low-level, high-detail plans that focus on:
- Technical implementation approach
- Code integration points and patterns
- Existing code reuse opportunities
- Test coverage planning
- Database and API design considerations

### Important Guidelines

**DO:**
- Analyze existing codebase thoroughly for integration patterns
- Plan for code reuse to avoid duplication
- Design with existing architectural patterns in mind
- Plan comprehensive test coverage
- Consider performance and security implications
- Use all available tools except Edit (read-only analysis)

**DO NOT:**
- Actually implement code (that's for the implementation phase)
- Introduce unnecessary complexity
- Ignore existing code patterns and conventions
- Skip test planning

### Output Location
Save your planning documents in the `codegen/plans/` directory.

### Planning Structure
Your detailed plans should typically include:

1. **Technical Overview** - High-level technical approach and architecture
2. **Implementation Strategy** - Step-by-step implementation plan
3. **Code Integration** - How this integrates with existing codebase
4. **Database Changes** - Schema changes, migrations, data considerations
5. **API Design** - Endpoints, request/response structures, validation
6. **Test Plan** - Unit tests, integration tests, test scenarios
7. **Performance Considerations** - Potential bottlenecks and optimizations
8. **Security Considerations** - Authentication, authorization, data protection
9. **Dependencies** - External libraries, internal modules, prerequisites
10. **Implementation Order** - Logical sequence of development tasks

### Context Available
- `PROJECT_CONTEXT.md` - Main project knowledge base
- `SESSION_CONTEXT.md` - This planning session context
- Feature name: {{FEATURE_NAME}} (if specified)
- Full codebase access for analysis (read-only)

### Code Analysis Approach
Use these tools to understand the existing codebase:
- **Grep** - Search for patterns, functions, similar implementations
- **Glob** - Find relevant files by name/extension
- **Read** - Examine existing code structure and patterns
- **Task** - Use agent for complex searches across the codebase

### Integration Focus
- Look for existing similar functionality to reuse
- Follow established patterns and conventions
- Consider how changes impact existing features
- Plan for backward compatibility where needed

### Next Steps
After detailed planning, the typical workflow is:
1. **Bird-eye planning** (`ocg bird-eye`) → High-level feature planning
2. **Detailed planning** (you are here) → Technical implementation planning  
3. **Implementation** (`ocg new`) → Create workspace and build the feature

Remember: This is about technical precision and thorough preparation. Plan now, implement later.