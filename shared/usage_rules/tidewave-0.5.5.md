# Tidewave

Tidewave is a development-only coding agent platform that integrates with web applications to enable AI agents to read code, execute tests, query databases, and inspect runtime state during development. It provides runtime-focused tooling through the Model Context Protocol (MCP) for full-stack web development.

## Quick Start

### Installation

Download platform-specific binaries from Tidewave:

- **macOS**: Apple Silicon or Intel versions
- **Linux**: AppImage for x86_64 or ARM64
- **Windows**: x64 executable (recommended for WSL)

After installation, Tidewave launches a service on `http://localhost:9832` accessible via web browser.

### Configuration

1. **Desktop app**: After starting Tidewave, enter your web application's address in the welcome screen
2. **CLI alternative**: For containerized/remote deployments, use command-line binaries with `./tidewave --help` for options
3. **MCP setup**: Add Tidewave MCP server to your editor config as type `http` pointing to `/tidewave/mcp` at your app's port (e.g., `http://localhost:4000/tidewave/mcp`)

### Framework Support

Tidewave provides integration guides for: Django, FastAPI, Flask, Next.js, Phoenix, Ruby on Rails, TanStack Start, and Vite.

## Core Concepts

### Runtime Integration (MCP)

Tidewave integrates coding agents with application runtimes through the Model Context Protocol, enabling:

- **Code Analysis**: Project evaluation, source location discovery, documentation retrieval
- **Database Access**: SQL query execution, schema inspection, model introspection
- **Runtime Monitoring**: Log retrieval and code execution within application context
- **Package Documentation**: Library reference lookups across project dependencies

### Development-Only Design

Tidewave is explicitly a development tool. It must **never run in production**—treat it like a web console or REPL. The tool enables agents to execute code within your application, making it a powerful development companion but unsuitable for production environments.

### Programming Language Notation

Unlike traditional IDE tools (LSP), Tidewave uses programming language notation familiar to developers. This allows agents to explore codebases beyond existing usage patterns and perform dynamic analysis where frameworks use metaprogramming—particularly valuable for web development scenarios.

## Configuration

### Desktop Application

- Tidewave must run on the same machine as your web server
- Defaults to localhost-only access with framework-level development restrictions
- The system menu bar provides quick access to the running service

### CLI Deployment

For distributed/containerized setups, use CLI binaries with options:

- Default: restricted to localhost with security enforcement
- `--allow-remote-access`: Enable remote access (use with caution)
- `--allowed-origins`: Specify permitted request origins

### Editor Integration

Configure Tidewave MCP in supported editors:

- Claude Code, Cursor, VS Code, Neovim, Zed (and others)
- Configure agent rules to encourage regular tool usage
- Test connectivity using `curl http://localhost:4000/tidewave/mcp`

### Troubleshooting

- Verify IPv4/IPv6 resolution for your app address
- Check editor logs for connection issues
- Ensure no unwanted compression between client and MCP endpoint
- MCP proxy available if direct connections fail

## Best Practices

### Security

- **Development-only**: Never enable Tidewave in production
- **Localhost default**: Keep the default localhost restriction; use remote access flags cautiously
- **Containerization**: Run Tidewave inside Docker or devcontainers to isolate execution to that environment
- **Dependency vetting**: Tidewave only reads documentation of dependencies already in your project—vet both dependencies and documentation sources
- **Prompt injection awareness**: Understand that coding agents can be manipulated through crafted text inputs

### Data Handling

- Prompts and messages are not logged unless explicitly opt-in
- Request metadata is collected for debugging
- Tool results are not retained
- Third-party providers may have separate data agreements

### Runtime Usage

- Use Tidewave for code exploration, testing, and database inspection during development
- Leverage MCP tools to enable agents to understand project structure dynamically
- Configure agent rules in your editor to encourage natural tool usage
- For remote development, prefer CLI deployment inside containerized environments

### Framework-Specific Patterns

- Consult framework-specific integration guides for optimal setup
- Core features (code analysis, DB access, logging, documentation) are consistently available across frameworks
- Some frameworks offer extended capabilities—check your framework's integration guide

---

**Version:** 0.5.5  
**Source:** [hexdocs.pm/tidewave](https://hexdocs.pm/tidewave/)  
**Generated:** 2026-04-25
