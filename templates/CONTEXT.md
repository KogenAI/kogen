# {{PLAN_TITLE}}

## Feature: {{FEATURE_NAME}}

<!-- Target ~200-300 lines. Use /refresh-context to archive completed work and consolidate learnings when it grows larger. -->

### Current Stage

- **Stage**: Not Started
- **Status**: Planning
- **Last Updated**: [Auto-updated by AI during implementation]

### Environment

- **Server**: http://localhost:{{PORT}} (server is running)
- **Database (dev)**: {{DB_NAME_PREFIX}}\_dev{{PARTITION}}
- **Database (test)**: {{DB_NAME_PREFIX}}\_test{{PARTITION}}
- **Branch**: feature/{{FEATURE_NAME}}

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

### Tech Stack

- Phoenix LiveView with Elixir
- PostgreSQL with Ecto
- Tailwind CSS
- MCP Servers: Tidewave (Elixir tools) + Playwright (browser automation)

### Important Notes

- **Database**: Set up and seeded via `mix setup` during initialization
- **Testing**: The seeds file (`priv/repo/seeds.exs`) contains test users for login testing
- **MCP Tools**: Use Tidewave for Elixir/Phoenix analysis and Playwright for browser automation
- **Development Rules**: Follow project coding standards and conventions

### Server Management

- **Phoenix Server**: Started automatically during workspace initialization
- **Server Logs**: Available in `./codegen/mix_phx_server.log`
- **Restart Server**: When you need to restart Phoenix during development, use:
  ```bash
  # Kill existing server
  lsof -ti tcp:{{PORT}} | xargs kill -9 2>/dev/null || true
  sleep 2
  # Start in background with logging
  script -F codegen/mix_phx_server.log mix phx.server >/dev/null 2>&1 &
  ```

### Development Workflow

**If the plan contains stages:**

1. **Implement one stage at a time** - Stop after completing each stage
2. **Write comprehensive tests** - Ensure all new code has proper test coverage
3. **Run CI checks** - Execute `./codegen/ci.sh` and ensure all checks pass
4. **Wait for user review** - Pause for user to review code and commit before proceeding to next stage
5. **Update this context** - Keep the "Current Stage" and "Implementation Progress" sections current

This staged approach ensures code quality and allows for proper review at each milestone.

### Available Git Commands

For detailed code analysis, you can use:

- `git diff main..HEAD` - See all changes from main branch
- `git diff --staged` - See staged changes
- `git diff` - See working directory changes

### Implementation Guidelines

- Avoid introducing unnecessary complexity
- Make sure all changes are covered with tests
- Follow the plan described in `./codegen/PLAN.md`
- Use project knowledge from `./codegen/PROJECT_CONTEXT.md`
- Follow established coding standards and project conventions
- **Keep this context file updated** as you progress through implementation stages
