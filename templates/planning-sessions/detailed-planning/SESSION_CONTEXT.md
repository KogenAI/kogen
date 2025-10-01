# Detailed Planning Session Context

## Session Details

- **Mode**: Detailed Planning
- **Feature**: {{FEATURE_NAME}}
- **Model**: Claude Sonnet
- **Started**: {{SESSION_TIMESTAMP}}

## Load These Rules

**MANDATORY FIRST ACTION**: After reading this context and PROJECT_CONTEXT.md, load planning rules:

1. **Load planning rules**:
   - `./codegen/rules/planning.md` - Planning structure, modular architecture, file hygiene requirements
2. **Identify feature type and load domain rules**:
   - Check `./codegen/rules/INDEX.md` for available domain rules
   - Based on feature description, load relevant domain rules:
     - **Phoenix/Elixir features**: Load `rules/subagents/phoenix.md` + `rules/subagents/elixir-code-generation.md`
     - **UI/design features**: Load `rules/subagents/ui-implementation.md` + `rules/subagents/phoenix.md`
     - **Testing features**: Load `rules/subagents/testing.md` + `rules/subagents/feature-tests.md`
     - **Translation features**: Load `rules/subagents/i18n.md`
     - **CI/deployment features**: Load `rules/subagents/ci-pipeline.md` + `rules/subagents/deployment.md`
     - **Multiple domains**: Load all relevant domain rules

**Why**: Plans with specific code must follow domain patterns. Loading appropriate rules prevents bad code patterns that won't get fixed during implementation.

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

**Figma Design Integration**

🚨 **CRITICAL**: If the user provides Figma node IDs or design references, you MUST handle them properly:

1. **Extract Figma designs**: Use Figma MCP `get_image(nodeId)` to get design references
2. **Document Figma references in your plan**: Include Figma URLs and node IDs directly in step files:

```markdown
## Design References

**Figma File**: https://www.figma.com/file/abc123/Project-Name
**Node IDs**:

- Login Form: `123:456`
- User Profile: `789:012`

## Visual Requirements

- Follow spacing tokens from Figma design system
- Use consistent color palette and typography
- Maintain responsive behavior as shown in designs
```

3. **Include design specifications in step plans**: Reference specific visual requirements, interactions, and responsive behavior from Figma designs

**DO NOT create/update FIGMA_MAP.md during planning** - that's for finished implementations only. Just document the Figma info in the plan for implementation reference.

**Planning Guidelines**

- Be thorough and specific in technical details
- Plan for code reuse and pattern consistency
- Consider both immediate implementation and future extensibility
- Plan comprehensive test coverage from the start

### Output Expectations

**Create Modular Plan Structure:**

For comprehensive features requiring detailed planning, create a modular structure to prevent context overload during implementation:

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

**What to include:**

**In overview.md:**

- Feature goals and business requirements
- High-level architecture and approach
- Step sequence with explicit file references (e.g., "Step 1: Setup (see step-01-setup.md)")
- Dependencies between steps
- Success criteria

**In step files (TDD APPROACH - CRITICAL):**

- **IMPLEMENTATION + TESTS TOGETHER**: Each step must include both feature implementation AND comprehensive tests
- **Complete CI readiness**: Step completion means ALL verification passes (compilation, tests, Credo, coverage, formatting)
- Specific technical implementation approach for that step
- **Test plans integrated with implementation** - not separated into Step 4
- Database schema changes and migration plans (if applicable)
- API endpoint specifications (if applicable)
- Component and module structure for that step

- **UI/design specifications**: Reference specific Figma node IDs, visual requirements, interactions (if applicable)
- Detailed test plans for that step
- Code examples and patterns to follow
- Prerequisites and dependencies for that step
- **Coverage requirements**: Ensure new code meets project coverage thresholds
- **MANDATORY FOR UI FEATURES**: Include translation requirements for all user-facing text, labels, messages
- **MANDATORY FOR DEPLOYMENT**: Include deployment configuration requirements for devops-manager

**🚨 CRITICAL CHANGE: TDD-First Planning**

**OLD APPROACH (causes ping-pong)**:

- Step 1: Auth implementation
- Step 2: Dashboard features
- Step 3: Charts
- Step 4: Tests for everything

**NEW APPROACH (TDD - prevents ping-pong)**:

- Step 1: Auth implementation + auth tests
- Step 2: Dashboard features + dashboard tests
- Step 3: Charts + chart tests
- Step 4: Integration tests only

**WHY**: Writing tests separately in Step 4 causes CI failures during Steps 1-3, leading to back-and-forth between verification-engineer and feature-developer. TDD approach ensures each step is CI-ready before moving forward.

### Implementation Readiness

Your plan should be detailed enough that an engineer can:

- Understand exactly what needs to be built
- Follow a clear implementation sequence
- Know what tests to write
- Understand integration requirements
- Identify potential risks and challenges

### 🚨 MANDATORY: Hallucination Check Before Finalizing

**CRITICAL**: After writing your plan, you MUST verify it against official documentation to catch hallucinations.

**PROCESS**:

1. **Identify External Dependencies**: List all libraries, frameworks, tools mentioned in your plan
2. **Verify Each Dependency**:
   - Use WebFetch or WebSearch to check official documentation
   - Verify syntax, API patterns, configuration options
   - Confirm features and capabilities actually exist
3. **Check Common Hallucination Risks**:
   - ❌ Library/function names (e.g., claiming "PhoenixTest.Playwright" exists)
   - ❌ Configuration order (e.g., wrong setup sequence in test_helper.exs)
   - ❌ API return values (e.g., returning `context` instead of `{:ok, context}`)
   - ❌ Parameter syntax (e.g., wrong pattern matching format)
   - ❌ Module names (e.g., incorrect namespace paths)
4. **Document Verification**: Add "Verified Against Documentation" section to overview.md:

```markdown
## Verified Against Documentation

- ✅ Cucumber 0.4.1: Verified setup, step syntax, return values
- ✅ Phoenix LiveView: Confirmed testing patterns from hexdocs
- ✅ Ecto: Verified migration syntax and schema patterns
```

5. **Fix Hallucinations**: Update ALL affected files (overview + step files) with corrections

**WHEN TO VERIFY**:

- **NEW dependencies**: Any library/framework not already in project dependencies
- **SPECIFIC syntax**: Code examples, configuration, API calls
- **TECHNICAL details**: Setup order, return types, pattern matching
- **CRITICAL features**: Core functionality that plan depends on

**Example Hallucinations This Would Catch**:

- ❌ Using `Cucumber.compile_features!()` before `ExUnit.start()` (wrong order)
- ❌ Step definitions returning `context` instead of `{:ok, context}`
- ❌ Claiming a library exists when it doesn't
- ❌ Wrong parameter extraction syntax

**If you find hallucinations**: Correct them immediately in ALL plan files before claiming plan is complete.

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
- **TDD approach aligns with orchestrator workflow**: feature-developer implements code+tests, then verification-engineer checks

Remember: This is about technical precision and implementation readiness. The better your plan, the smoother the orchestrated implementation will be.
