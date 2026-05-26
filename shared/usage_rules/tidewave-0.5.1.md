# tidewave

Tidewave is an AI-enhanced development environment for Elixir projects. It integrates with editors and coding agents via the Model Context Protocol (MCP), providing AI agents access to your project's code, database, logs, and documentation—enabling them to debug, inspect, and execute code within your application context.

## Quick Start

### Installation

Add Tidewave to your Elixir project dependencies:

```elixir
def deps do
  [
    {:tidewave, "~> 0.5"}
  ]
end
```

Run `mix deps.get` to install.

### Basic Setup

For Phoenix applications, Tidewave provides web UI at `http://localhost:4000/tidewave` and MCP endpoint at `http://localhost:4000/tidewave/mcp`.

Add to your router configuration to enable endpoints. For local development, no additional configuration is required—Tidewave auto-initializes.

### Connecting Your Editor

Configure your editor to use the HTTP MCP endpoint:

```
Type: http
Endpoint: http://localhost:4000/tidewave/mcp
```

Once connected, your AI agent can access project tools automatically.

## Core Concepts

### Available Tools

Tidewave provides these AI-accessible tools:

**Code & Documentation**

- `get_docs` - Access documentation for modules and functions
- `get_source_location` - Find where modules/functions are defined in your codebase
- `search_package_docs` - Search Hex package documentation (Phoenix projects only)

**Application Inspection**

- `get_logs` - Retrieve application logs for debugging
- `get_models`/`get_schemas` - Access data model definitions and database schemas
- `get_code_connect_map` - View Figma component mappings and design system connections

**Runtime Execution**

- `project_eval` - Execute Elixir code within your project context
- `execute_sql_query` - Run database queries using your application's models and context

### Tool Access Pattern

AI agents access these tools automatically when connected via MCP. You can ask the agent to:

- Execute database queries directly without external tools
- Check WebSocket connections and process state
- Find and inspect module definitions
- Debug errors by examining logs and tracing processes
- Search your dependencies and documentation

## Configuration

### Phoenix Integration

Tidewave automatically integrates with Phoenix applications. No explicit configuration required for basic functionality.

**Optional: Enable Specific Tools**

Configure which tools are available to agents in your Tidewave settings (varies by deployment):

- Development: All tools enabled by default
- Production: Restricted to documentation and read-only inspection tools
- Custom: Configure per tool in agent rules

### MCP Proxy for Stdio-Only Editors

If your editor only supports stdio MCP servers (not HTTP):

Use the `mcp_proxy_elixir` package to bridge HTTP Tidewave to stdio:

```bash
# Setup proxy as documented in mcp_proxy_elixir
# Then point your editor to the stdio proxy instead of HTTP endpoint
```

### Agent Rules Configuration

Leverage Tidewave's capabilities in agent rules to make tool usage automatic:

```markdown
# In your editor's agent configuration

- Always use `get_docs` when understanding framework features
- Use `execute_sql_query` for database inspection without manual steps
- Apply `get_logs` when debugging application errors
```

## Best Practices

### Effective Tool Usage

**Documentation Access**

- Use `get_docs` for all framework-related questions
- Use `search_package_docs` to understand dependency APIs before implementation
- Reference source locations with `get_source_location` when contributing to the codebase

**Database Inspection**

- Use `execute_sql_query` to validate data models before implementation
- Query live data during feature development to understand relationships
- Inspect schemas with `get_schemas` before writing migrations

**Debugging Workflow**

- Start with `get_logs` to identify error patterns
- Use `get_source_location` to navigate to relevant code
- Apply `project_eval` to test fixes in project context before committing

**Performance Optimization**

- Configure agent rules to use tools automatically (no explicit requests needed)
- Combine tool calls: fetch docs + schema + logs in parallel for faster debugging
- Cache documentation references in agent memory for repeated lookups

### Limitations & Considerations

- **Web UI features** (`/tidewave` route) unavailable in MCP mode—point-and-click prompting and contextual testing exclusive to browser
- **Production constraints** - Restrict `project_eval` and `execute_sql_query` to read-only operations in non-development environments
- **Agent awareness** - Not all agents automatically know about Tidewave tools; configure agent rules explicitly for tool discovery

### Security Considerations

- `project_eval` executes code in your application context—use only with trusted agents
- Restrict database access in production; consider read-only database users for non-development environments
- Tidewave logs all tool executions for audit trails in production deployments

---

**Version:** 0.5.1
**Source:** [hexdocs.pm/tidewave](https://hexdocs.pm/tidewave/)
**Generated:** 2025-11-04
