# {{PLAN_TITLE}}

## Feature: {{FEATURE_NAME}}

<!-- Target ~50-100 lines. Detailed step progress stored in ./codegen/context/ step files. -->

### Step Context Structure

**Main Context (this file)**: Current focus, next steps, session tracking
**Step Details**: `@./codegen/context/` - Detailed progress and lessons for each step

- Only load step files when working on or reviewing that specific step
- Step files preserve detailed implementation decisions and lessons learned
- **Current Step**: [Update this with current step file, e.g., "step-01-setup.md"]

### Implementation Plan Reference

**📋 CRITICAL**: Implementation plan is in modular structure at `@./codegen/plan/`

- **Overview**: `@./codegen/plan/overview.md` - Feature goals, architecture, step sequence
- **Step Details**: `@./codegen/plan/steps/` - Detailed implementation for each step
- **READ OVERVIEW IMMEDIATELY** if context was lost during auto-compacting
- **Load step files as needed** - Only read specific steps relevant to current work
- **Figma Requirements**: Visual/design specifications documented in relevant step files
- **Architecture**: Complete technical architecture defined in overview and step files
- **Testing Strategy**: Comprehensive testing requirements in step files
- **Completion Criteria**: Success criteria specified in overview.md

### Current Stage

- **Stage**: Not Started
- **Status**: Planning
- **Last Updated**: [Auto-updated by AI during implementation]
- **Current Step**: [e.g., "step-01-setup.md"]
- **Verification Evidence**: [Added when step is complete]
  - ✅ `./codegen/ci.sh` - [CI results]
  - ✅ Feature-specific tests - [Test results]
  - ✅ Step context file created - [File name]

### Environment

- **Server**: http://localhost:{{PORT}} (server is running)
- **Database (dev)**: {{DB_NAME_PREFIX}}\_dev{{PARTITION}}
- **Database (test)**: {{DB_NAME_PREFIX}}\_test{{PARTITION}}
- **Branch**: feature/{{FEATURE_NAME}}
- **Workspace**: {{WORKSPACE_PATH}} (work ONLY in this directory)

### Feature Impact Analysis

- **Modules Affected**: [List of existing modules this feature touches]
- **New Components**: [New files/modules being created]
- **Architecture Changes**: [How this changes the overall structure]
- **Integration Points**: [How this connects to existing systems]

### Implementation Progress

- **Completed**: [What has been implemented so far]
- **Current Focus**: [What is being worked on now]
- **Next Steps**: [What comes next in the current stage]
- **Blockers**: [Any issues or dependencies preventing progress]

### Subagent Coordination Status

**Active Subagents** (for current step):

- **feature-developer**: [Not Started | In Progress | Complete | Blocked]
- **ui-specialist**: [Not Started | In Progress | Complete | Blocked]
- **test-engineer**: [Not Started | In Progress | Complete | Blocked]
- **verification-engineer**: [Not Started | In Progress | Complete | Blocked]
- **devops-manager**: [Not Started | In Progress | Complete | Blocked]
- **translator**: [Not Started | In Progress | Complete | Blocked]

**Integration Status**:

- **Pending Handoffs**: [Which subagent is waiting for another to complete]
- **Integration Issues**: [Any conflicts or coordination problems]
- **Collaboration Notes**: [Important coordination information]

### Tech Stack

- Phoenix LiveView with Elixir
- PostgreSQL with Ecto
- Tailwind CSS
- MCP Servers: Tidewave (Elixir tools) + Playwright (browser automation) + Figma (design analysis)

### Important Notes

- **Database**: Set up and seeded via `mix setup` during initialization
- **Testing**: The seeds file (`priv/repo/seeds.exs`) contains test users for login testing
- **MCP Tools**: Use Tidewave for Elixir/Phoenix analysis and Playwright for browser automation
- **Development Rules**: Follow project coding standards and conventions

### Server Management

- **Phoenix Server**: Running on port {{PORT}}
- **Server Logs**: Available in `./codegen/mix_phx_server.log`
- **Server Management**: See `shared/server-management.md` for restart rules and coordination

### Development Workflow

**Single-Level Subagent Delegation Workflow:**

1. **Orchestrate step implementation** - main agent delegates directly to specialized subagents:

   - **feature-developer**: Phoenix/Elixir code implementation
   - **ui-specialist**: Figma design implementation and styling
   - **test-engineer**: Writes comprehensive tests including feature tests
   - **verification-engineer**: Runs tests and CI verification, reports findings
   - **devops-manager**: Infrastructure and deployment
   - **translator**: Internationalization and localization

2. **Delegate verification** - main agent delegates ALL testing and CI to verification-engineer
3. **Integration coordination** - main agent ensures all subagent work integrates properly
4. **Step completion** - Update context with verification evidence before proceeding
5. **Wait for user review** - Pause for user to review code and commit before proceeding to next stage

This single-level approach reduces memory usage while maintaining specialized expertise and clear responsibility boundaries.

### Available Git Commands

For detailed code analysis, you can use:

- `git diff main..HEAD` - See all changes from main branch
- `git diff --staged` - See staged changes
- `git diff` - See working directory changes

### Session Tracking

- **Start Time**: [REQUIRED - Log immediately when starting work: `date`]
- **Current Session Focus**: [What specific task is being worked on this session]
- **User Status**: [Active/AFK - current user engagement level]
- **Estimated Duration**: [Expected time to complete current work]
- **Status**: [Brief status of current progress]

**CURRENT WORK**: [Detailed description of what is actively being implemented/debugged]

### Implementation Guidelines

**PRIMARY RULE**: If resuming work or context was compacted, **READ `@./codegen/plan/overview.md` FIRST**

**SUBAGENT ORCHESTRATION**:

- **Delegation pattern**: Use Task tool to launch appropriate subagents with clear step context
- **Integration responsibility**: main agent coordinates between subagents and resolves conflicts
- **See orchestration rules** for specific delegation strategies and coordination patterns

**IMPLEMENTATION APPROACH**:

- **Modular plan structure** contains all requirements, architecture, and completion criteria
- **Overview** provides goals and step sequence, **step files** provide detailed implementation
- Load step files as needed for current work to avoid context overload
- Avoid introducing unnecessary complexity
- Make sure all changes are covered with tests (via test-engineer delegation)
- **For Figma features**: Visual specifications and node IDs are in relevant step files
- Use project knowledge from `./codegen/PROJECT_CONTEXT.md`
- Follow established coding standards and project conventions
- **Keep this context file updated** as you progress through implementation stages
- **MANDATORY**: Log session start time immediately when beginning any work

**CONTEXT LOSS RECOVERY**: If you're unsure about requirements or next steps, start with `@./codegen/plan/overview.md` then load specific step files as needed

```

```
