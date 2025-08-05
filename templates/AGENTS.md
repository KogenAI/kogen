# AGENTS.md

Guidance for AI assistants working with this Phoenix LiveView repository.

## File Reference Convention

When you see `FILE: ./path/to/file.md` in any document, this indicates a loadable resource.

- These are NOT auto-loaded - you must decide whether and when to load them
- Load files only when their content is relevant to your current task
- Use your Read tool to load the file when needed

## Workspace Understanding

### 🚨 CRITICAL: OCG Workspace Understanding

**YOU ARE IN AN OCG WORKSPACE (GIT WORKTREE)**:

- **WORKSPACE = CURRENT DIRECTORY**: Contains the complete project files
- **REPO ROOT = PARENT DIRECTORIES**: `../` or `../../` paths lead to main repository - NEVER GO THERE
- **ALL FILES ARE HERE**: Everything you need is in the current workspace directory

### Path Rules - NEVER VIOLATE THESE:

- ✅ **CORRECT**: `./codegen/CONTEXT.md` (current directory)
- ❌ **WRONG**: `../CONTEXT.md` or `../../codegen/CONTEXT.md`
- ✅ **CORRECT**: `./priv/gettext/` (translation files)
- ❌ **WRONG**: `../priv/gettext/`

## Common File Locations (All in Current Directory):

- **Context**: `./codegen/CONTEXT.md`
- **Project Context**: `./codegen/PROJECT_CONTEXT.md`
- **Rules**: `./codegen/rules/RULES.md`
- **Plan**: `./codegen/plan/overview.md`
- **Translations**: `./priv/gettext/`
- **Phoenix Config**: `./config/`
- **Application Code**: `./lib/`

## Universal Context Files (Available to ALL agents)

**ALWAYS READ THESE**:

1. **FILE: ./codegen/PROJECT_CONTEXT.md** - Project details, architecture, and patterns
2. **FILE: ./codegen/rules/RULES.md** - Rule index (load domain-specific rules as needed)

**Note**: The {{AGENT_CONTEXT_FILE}} (AGENTS.md/CLAUDE.md) is automatically loaded - it contains universal guidance for all agents. Different agent types may read additional context files specific to their role.

## Subagent File Loading Architecture

**Understanding which files each agent type loads:**

### Main Agent (orchestrator role)

- `templates/NEW_PROMPT.md` or `templates/RESUME_PROMPT.md` (includes orchestration guidance)
- `templates/AGENTS.md` or `templates/CLAUDE.md` (auto-loaded via {{AGENT_CONTEXT_FILE}})
- `./codegen/PROJECT_CONTEXT.md` (project-specific details)
- `./codegen/CONTEXT.md` (implementation progress)
- `./codegen/plan/overview.md` (feature overview)
- `./codegen/plan/steps/step-XX-name.md` (current step plan)

### Specialized Subagents (single-level delegation only)

- `templates/claude-subagents/[subagent-name].md` (role definition)
- `templates/AGENTS.md/CLAUDE.md` (auto-loaded universal guidance)
- `./codegen/CONTEXT.md` (workspace info: ports, commands, current progress)
- `./codegen/PROJECT_CONTEXT.md` (project-specific details)
- Domain-specific rules (e.g., phoenix.md, testing.md, i18n.md)
- Step context + step plan + workspace details (passed via main agent delegation)

### Special Cases

- **ui-specialist**: Also loads `./codegen/FIGMA_MAP.md` when doing Figma work
- **qa-engineer**: Loads testing.md, ci-pipeline.md rules
- **translator**: Loads i18n.md rules
- **devops-manager**: Loads deployment.md rules

## Available Tools

### Standard Tools

- **Read, Write, Edit, MultiEdit**: For file operations
- **Bash**: For standard commands like `curl`, `mix`, `npm`, etc.
- **Grep, Glob**: For searching files
- **TodoWrite**: For task management
- **WebFetch**: For accessing external URLs

### MCP Tools (When Available)

- **Tidewave MCP**: Elixir/Phoenix development assistance
- **Playwright MCP**: Browser automation and testing
- **Figma MCP**: Design extraction and analysis

### Tool Usage Notes

- **Never run MCP commands as bash** - they will fail
- Use fallback strategies when MCP tools aren't available
- Use WebFetch for external resources when MCP tools fail

## Agent Type Awareness

### Universal Guidance (Applies to ALL agents)

- **Workspace Isolation**: NEVER navigate to parent directories (`../` or `../../`)
- **Phoenix LiveView**: This is LiveView, not REST API - use event handlers, not endpoints
- **Pattern Following**: Follow existing codebase patterns and conventions
- **Context Loading**: Use your Read tool to understand context before making changes

### Single-Level Delegation Architecture

**MAIN AGENT = ORCHESTRATOR**: The main thread acts as orchestrator, delegating directly to specialized subagents.

**DELEGATION PATTERN**: Main Agent → Subagent (single level only)

- ✅ **Main agent delegates to**: feature-developer, qa-engineer, ui-specialist, devops-manager, translator, manual-tester
- ❌ **No multi-level**: Subagents NEVER delegate to other subagents
- ❌ **No orchestrator subagent**: Removed due to memory constraints

### Subagent Coordination

**STAR PATTERN**: All subagents report back to main agent only

```
feature-developer ←→ main-agent ←→ qa-engineer
      ↑              (orchestrator)        ↓
      ↑                    ↕               ↓
ui-specialist    ←→ main-agent ←→ devops-manager
```

**KEY RULES**:

- **Main agent coordinates**: All delegation routing handled by main agent
- **No cross-delegation**: Subagents only communicate with main agent
- **qa-engineer verification**: Final verification always delegated to qa-engineer
- **Single step focus**: Complete one plan step fully before moving to next

## 🚨 MANDATORY: Step Context File Updates

**SUBAGENT WORKSPACE CONTEXT REQUIREMENTS**:

### MANDATORY for ALL Subagents:

1. **ALWAYS read CONTEXT.md FIRST** - Contains critical workspace info:

   - Phoenix server port (e.g., 4001)
   - Test server port (e.g., 4101)
   - Playwright MCP port (e.g., 8901)
   - Database partition info
   - Available mix aliases and commands
   - Current implementation progress

2. **ALWAYS read phoenix.md rule** - Contains critical server management rules:

   ```
   ## Server
   - Assume the server is running
   - Don't assume the port is 4000. Get the correct port from Endpoint configuration
   - Don't restart the server - it supports hot reloading
   - Only after updating config files, adding/updating Oban workers, or any GenServer/Supervisor, you need to restart the server
   ```

3. **Read step context file** - `./codegen/context/step-XX-name.md` for coordination
4. **Load domain rules** - Only additional rules relevant to your role (testing.md, ci-pipeline.md, etc.)

### 🚨 CRITICAL SERVER RULES:

- **NEVER kill or restart Phoenix server** unless modifying config/workers/supervisors
- **NEVER run `mix phx.server`** - server is already running with hot reload
- **NEVER stop running processes** - they support live code updates
- Get actual port from CONTEXT.md, don't assume 4000

### Main Agent Delegation Requirements:

When delegating to subagents, ALWAYS include:

```
Task(
  description="[Task description] for step X",
  prompt="You are working on: Step X - [Step Name]

  MANDATORY FIRST ACTIONS:
  1. Read ./codegen/CONTEXT.md (workspace ports, commands, progress)
  2. Read ./codegen/context/step-XX-name.md (coordination with other agents)
  3. Read step plan: ./codegen/plan/steps/step-XX-name.md (requirements)

  WORKSPACE INFO:
  - Phoenix Port: [port from CONTEXT.md]
  - Test Port: [test-port from CONTEXT.md]
  - Playwright MCP Port: [playwright-port from CONTEXT.md]
  - Branch: feature/[feature-name]

  SPECIFIC TASK:
  [Detailed task requirements - do NOT just reference the plan]

  COMPLETION REQUIREMENTS:
  - Update step context file with your work
  - [Specific completion criteria]",
  subagent_type="[subagent-type]"
)
```

**EVERY AGENT AND SUBAGENT MUST UPDATE STEP CONTEXT FILES**:

### Before Starting Work:

1. **Read current step context file**: `./codegen/context/step-XX-name.md` (matches current step plan)
2. **Check what other agents have done**: Review existing progress, issues, solutions
3. **Understand integration points**: See dependencies and coordination needs

### During Work:

1. **Document progress regularly**: Update step context with status, findings, decisions
2. **Note integration challenges**: Document any cross-subagent coordination issues
3. **Record deviations**: Explain any changes from original plan requirements

### Before Completing/Delegating:

1. **MANDATORY UPDATE**: Update step context file with:

   - **Work completed**: Specific tasks finished and evidence
   - **Issues encountered**: Problems found and how they were resolved
   - **Integration notes**: How your work connects with other subagents
   - **Next actions needed**: What still needs to be done for this step
   - **Verification status**: What verification is needed/completed

2. **Use collaboration templates** from `./codegen/rules/collaboration.md` for consistent updates

### Step Context File Format:

```markdown
## [Agent Name] Work Status - [Timestamp]

### Completed:

- Specific task 1 with evidence/location
- Specific task 2 with evidence/location

### Issues Resolved:

- Problem X: Solution Y (files affected: ...)

### Integration Notes:

- Dependencies on other agents: ...
- Coordination points: ...

### Still Needed:

- Task A (assigned to: agent-type)
- Task B (verification needed)

### Files Modified:

- path/to/file1.ex - reason
- path/to/file2.exs - reason
```

**NO EXCEPTIONS**: Every agent must update step context before finishing work or delegating to another agent.

## Rule Loading

Load `./codegen/rules/RULES.md` to see available domain-specific rules. Load only rules relevant to your current task and agent type.
