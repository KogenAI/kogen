# {{PLAN_TITLE}}

Implement the feature described in PLAN.md for this Phoenix/Elixir project.

### Environment

- **Server**: http://localhost:{{PORT}} (already started and ready)
- **Database (dev)**: bemeda_personal_dev{{PARTITION}}
- **Database (test)**: bemeda_personal_test{{PARTITION}}
- **Branch**: feature/{{FEATURE_NAME}}

### Tech Stack

- Phoenix LiveView with Elixir
- PostgreSQL with Ecto
- Tailwind CSS
- MCP Servers: Tidewave (Elixir tools) + Playwright (browser automation)

### Important Notes

- **Database**: Set up and seeded via `mix setup` during initialization
- **Testing**: The seeds file (`priv/repo/seeds.exs`) contains test users for login testing
- **MCP Tools**: Use Tidewave for Elixir/Phoenix analysis and Playwright for browser automation

### Development Workflow

**If the plan contains stages:**
1. **Implement one stage at a time** - Stop after completing each stage
2. **Write comprehensive tests** - Ensure all new code has proper test coverage
3. **Run CI checks** - Execute `make ci` and ensure all checks pass
4. **Wait for user review** - Pause for user to review code and commit before proceeding to next stage

This staged approach ensures code quality and allows for proper review at each milestone.

### Request

Analyze the codebase and implement the plan step by step. Use MCP tools for Elixir analysis and database operations.

Start by reviewing PLAN.md and then begin implementing the feature according to the plan. If the plan has stages, follow the staged development workflow above.
