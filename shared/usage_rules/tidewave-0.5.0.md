# tidewave

**Browser-based coding agent deeply integrated with web frameworks** (Phoenix and Rails). Tidewave runs alongside your web application in the browser, providing development assistance through a dedicated web interface and Model Context Protocol (MCP) integration.

## Quick Start

### Installation

1. Add the `tidewave` package to your web application (via Hex or framework-specific package)
2. Access `/tidewave` endpoint in your browser during development
3. Begin using Tidewave Web immediately

**Framework-Specific Repos:**

- **Phoenix**: https://github.com/tidewave-ai/tidewave_phoenix
- **Rails**: https://github.com/tidewave-ai/tidewave_rails

### MCP Configuration

Add Tidewave MCP server as an HTTP (streamable) endpoint:

```
http://localhost:4000/tidewave/mcp
```

For stdio-only tools, use the included MCP proxy.

## Core Concepts

### Available Tools

Both Phoenix and Rails support:

- `project_eval` - Execute code in your project context
- `get_docs` - Access documentation for project dependencies
- `get_source_location` - Find module/function definitions
- `get_logs` - View application logs
- `get_models` / `get_schemas` - Access data models/schemas
- `execute_sql_query` - Run SQL queries

Rails additionally supports:

- `search_package_docs` - Search across package documentation

### Architecture

Tidewave implements three security layers:

1. **Localhost binding** - Restricts access to local machine only
2. **Remote IP verification** - Validates requests originate from current machine
3. **Origin header checks** - Ensures browser requests match development URL

### Key Characteristics

- **Development-only**: Must never be enabled in production
- **Code execution capable**: AI agents can execute arbitrary code within project context
- **Framework-integrated**: Deep integration with application state and models
- **Browser-based**: Access through web interface at `/tidewave` endpoint

## Configuration

### Basic Setup

Tidewave works out-of-the-box with sensible defaults after adding the package:

```
1. Add tidewave dependency
2. Access http://localhost:PORT/tidewave
3. Begin coding assistance immediately
```

### Agent Integration

Configure agent rules to encourage automatic tool usage:

- Instruct agents to "always use Tidewave's tools for evaluating code"
- Encourage use of `get_docs` for documentation lookups
- Recommend `get_source_location` for navigating definitions
- Set up automatic database querying with `execute_sql_query`

### Editor Integration

Tidewave MCP is supported in:

- Claude Code
- Cursor
- Neovim
- OpenCode
- VS Code
- Windsurf
- Zed

### Container Support

Tidewave works out-of-the-box when using devcontainers with no additional configuration.

## Best Practices

### Security

⚠️ **CRITICAL**: Tidewave is a development tool—treat it like web consoles and REPLs:

- Never enable in production environments
- Never expose to network beyond localhost
- Assess code execution carefully before allowing agents to run commands
- Vet dependencies and their documentation (only project deps are accessible)

### Code Execution

- Run application in Docker or devcontainers to add security boundary
- Review commands before execution when code execution poses risks
- Use `project_eval` thoughtfully—agents have full project access
- Monitor database queries run via `execute_sql_query`

### Data Handling

- Prompts and responses are NOT stored by default (opt-in logging available)
- Metadata (tokens, latency) is collected for service improvement
- External service calls (`search_package_docs`, HTTP requests) may transmit data
- Evaluate and halt commands with data concerns

### Agent Configuration

- Configure rules to encourage tool usage automatically
- Set agent expectations about framework integration
- Document which tools are appropriate for your project context
- Establish conventions for database and documentation access

### Framework Integration

- Leverage framework-specific tools for your platform
- Use `get_models`/`get_schemas` to understand data structure
- Reference `get_source_location` for navigation vs file searches
- Use `get_logs` to debug agent-initiated changes

---

**Version:** 0.5.0
**Source:** [hexdocs.pm/tidewave](https://hexdocs.pm/tidewave/)
**Generated:** 2025-10-28
