# {{PLAN_TITLE}}

Implement the feature described in PLAN.md for this Phoenix/Elixir project.

### Environment

- **Server**: http://localhost:{{PORT}} (will start automatically)
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

### Request

Analyze the codebase and implement the plan step by step. Use MCP tools for Elixir analysis and database operations.

Start by reviewing PLAN.md and then begin implementing the feature according to the plan.
