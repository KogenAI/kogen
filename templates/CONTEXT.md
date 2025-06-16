# {{PLAN_TITLE}}

## Feature: {{FEATURE_NAME}}

### Environment

- **Server**: http://localhost:{{PORT}} (server is running)
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
- **Cursor Rules**: Available in `.cursor/rules/` directory - enforce these in your implementations

### Development Workflow

**If the plan contains stages:**
1. **Implement one stage at a time** - Stop after completing each stage
2. **Write comprehensive tests** - Ensure all new code has proper test coverage
3. **Run CI checks** - Execute `make ci` and ensure all checks pass
4. **Wait for user review** - Pause for user to review code and commit before proceeding to next stage

This staged approach ensures code quality and allows for proper review at each milestone.

### Available Git Commands

For detailed code analysis, you can use:

- `git diff main..HEAD` - See all changes from main branch
- `git diff --staged` - See staged changes
- `git diff` - See working directory changes

### Implementation Guidelines

- Avoid introducing unnecessary complexity
- Make sure all changes are covered with tests
- Follow the plan described in `codegen/PLAN.md`
- Enforce appropriate Cursor rules available in the `.cursor/rules` directory 
