# {{PLAN_TITLE}}

## Feature: {{FEATURE_NAME}}

<!-- Target ~50-100 lines. Detailed step progress stored in ./codegen/context/ step files. -->

### Work Context Structure

**Main Context (this file)**: Current focus, next steps, session tracking
**Work Contexts**: `@./codegen/context/` — persistent memory for delegations and issues

- **Check pending**: `ls ./codegen/context/PENDING-*` before starting new work
- **Issue contexts**: `PENDING-issues-*.md` — code review/verification findings
- **Step contexts**: `step-XX-*.md` — detailed progress per step
- **Status prefixes**: PENDING (awaiting), ACTIVE (in progress), RESOLVED (done)
- **Current Step**: [e.g., "step-01-setup.md"]

### Implementation Plan Reference

**CRITICAL**: Plan at `@./codegen/plan/`

- **Overview**: `@./codegen/plan/overview.md` — goals, architecture, step sequence
- **Step Details**: `@./codegen/plan/steps/` — detailed impl per step
- **READ OVERVIEW IMMEDIATELY** if context lost during auto-compacting
- **Load step files as needed** — only read steps relevant to current work

### Current Stage

- **Stage**: Not Started
- **Status**: Planning
- **Last Updated**: [Auto-updated by AI]
- **Current Step**: [e.g., "step-01-setup.md"]
- **Verification Evidence**: [Added when step complete]
  - ✅ `./codegen/ci.sh` — [CI results]
  - ✅ Feature-specific tests — [Test results]
  - ✅ Step context file created — [File name]

### Environment

- **Server**: http://localhost:{{PORT}} (server is running)
- **Database (dev)**: {{DB_NAME_PREFIX}}\_dev{{PARTITION}}
- **Database (test)**: {{DB_NAME_PREFIX}}\_test{{PARTITION}}
- **Branch**: feature/{{FEATURE_NAME}}
- **Workspace**: {{WORKSPACE_PATH}} (work ONLY in this directory)

### Feature Impact Analysis

- **Modules Affected**: [Existing modules this feature touches]
- **New Components**: [New files/modules being created]
- **Architecture Changes**: [How this changes overall structure]
- **Integration Points**: [How this connects to existing systems]

### Implementation Progress

- **Completed**: [What has been implemented]
- **Current Focus**: [What is being worked on now]
- **Next Steps**: [What comes next]
- **Blockers**: [Issues or dependencies preventing progress]

### Subagent Coordination Status

**Active Subagents** (for current step):

- **planner-phoenix**: [Not Started | In Progress | Complete | Blocked]
- **developer-phoenix-backend**: [Not Started | In Progress | Complete | Blocked]
- **developer-phoenix-frontend**: [Not Started | In Progress | Complete | Blocked]
- **reviewer-phoenix**: [Not Started | In Progress | Complete | Blocked]
- **committer**: [Not Started | In Progress | Complete | Blocked]

**COMPLETION GATE CHECKLIST** — MANDATORY SEQUENCE, NEVER SKIP:

- [ ] **Implementation**: developer-phoenix-backend / developer-phoenix-frontend reported complete
- [ ] **Verification**: dev-gate.sh hook appended `ALL CLEAR ✅` to step log
- [ ] **Code Review**: reviewer-phoenix reported `✅ QUALITY APPROVED`
- [ ] **STEP COMPLETE**: Only mark complete when all 3 gates pass

After ANY impl work → dev-gate.sh hook fires automatically; orchestrator reads verdict from `## dev-gate Section`. On `ALL CLEAR ✅` → delegate to reviewer-phoenix. NO EXCEPTIONS.

**CODE REVIEW FAILURE WORKFLOW** — if reviewer-phoenix reports `❌ QUALITY ISSUES FOUND`:

1. Save issues to `./codegen/context/PENDING-issues-YYYYMMDD-HHMMSS-code-review.md`
2. Delegate fixes to developer-phoenix-backend (or developer-phoenix-frontend) with context file path
3. After fixes, dev-gate.sh hook re-runs; restart review only after fresh `ALL CLEAR ✅`
4. Continue until `✅ QUALITY APPROVED`

**CURRENT DELEGATION:**

- **Task**: [Current delegation]
- **Subagent**: [Which subagent]
- **Started**: [Timestamp]
- **Work Context**: [Path to context file if created]

**Awaiting**: [What needs to happen next]

### Tech Stack

- Phoenix LiveView with Elixir
- PostgreSQL with Ecto
- Tailwind CSS
- MCP Servers: Tidewave (Elixir tools)

### Important Notes

- **Database**: Set up and seeded via `mix setup`
- **Testing**: `priv/repo/seeds.exs` contains test users
- **MCP Tools**: Use Tidewave for Elixir/Phoenix analysis
- **Development Rules**: Follow project coding standards

### Server Management

- **Phoenix Server**: Running on port {{PORT}}
- **Server Logs**: `./codegen/mix_phx_server.log`
- **Server Management**: See `shared/server-management.md`

### Development Workflow

1. **Orchestrate step impl** — delegate to specialized subagents:
   - **planner-phoenix**: Writes plan + delegation prompts (Phase 0)
   - **developer-phoenix-backend**: Phoenix/Elixir backend code (contexts, Ecto, Oban, mailers, controllers, schemas, migrations)
   - **developer-phoenix-frontend**: LiveView, HEEx, JS hooks, Tailwind, browser tests

2. **Verification** — dev-gate.sh SubagentStop hook runs CI/tests automatically; verdict appended to step log
3. **Integration coordination** — ensure subagent work integrates properly
4. **Step completion** — update context with verification evidence before proceeding
5. **Wait for user review** — pause before proceeding to next stage

### Available Git Commands

- `git diff main..HEAD` — all changes from main branch
- `git diff --staged` — staged changes
- `git diff` — working directory changes

### Implementation Guidelines

**If resuming or context was compacted:**

1. **CHECK PENDING**: `ls ./codegen/context/PENDING-*`
2. **READ OVERVIEW**: `@./codegen/plan/overview.md`
3. **CONTINUE PENDING**: work on PENDING contexts before starting new work

**SUBAGENT ORCHESTRATION:**

- Use Task tool to launch subagents with clear step context
- Main agent coordinates and resolves conflicts
- See orchestration rules for delegation strategies

**IMPLEMENTATION APPROACH:**

- Modular plan structure contains all reqs, architecture, and criteria
- Load step files as needed — avoid context overload
- Avoid unnecessary complexity
- All changes must have tests
- Use `./codegen/PROJECT_CONTEXT.md` for project knowledge
- **Keep this context file updated** as you progress
- **MANDATORY**: Log session start time immediately

**CONTEXT LOSS RECOVERY**: Unsure about reqs? Start with `@./codegen/plan/overview.md` then load specific step files.
