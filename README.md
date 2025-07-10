# Optimum Codegen

A powerful workspace management system for Phoenix/Elixir projects that creates isolated feature workspaces using git worktrees and Docker containers.

## Prerequisites

- Docker Desktop installed and running
- Git
- Cursor IDE (recommended) or VS Code
- Phoenix/Elixir project
- AI Assistant: Claude Code or OpenCode (both installed by `make install`)

## Configuration

The system automatically detects which git repository you're currently in and manages workspaces for that repository. No configuration needed!

## Quick Start

1. **Navigate to your project repository**
2. **Initialize project context (one-time setup):**
   ```bash
   ocg setup
   ```
3. **Prepare environment (choose one):**

   Native mode (uses your local Elixir/Erlang):

   ```bash
   ocg prepare
   ```

   Container mode (builds Docker image and base volumes):

   ```bash
   ocg prepare --container
   ```

4. **Create a new feature workspace:**

   Native mode:

   ```bash
   ocg new my-feature
   ```

   Container mode:

   ```bash
   ocg new my-feature --container
   ```

5. **List all workspaces:**
   ```bash
   ocg ls
   ```
6. **Resume an existing workspace:**

   Native mode:

   ```bash
   ocg resume my-feature
   ```

   Container mode:

   ```bash
   ocg resume my-feature --container
   ```

## How It Works

### Docker Integration

Each workspace can run in an isolated Docker container with:

- Ubuntu 24.04 base with project-specific Elixir/Erlang versions (from .tool-versions)
- Pre-installed dependencies from base volumes (if `ocg prepare --container` was run)
- Isolated ports, database, and environment
- Automatic container lifecycle management

### File Structure

- **Project Context** is stored in `{CURRENT_REPO}/codegen/PROJECT_CONTEXT.md`
- **Workspaces** are created in `{CURRENT_REPO}/codegen/workspaces/`
- **Plans** are stored in `{CURRENT_REPO}/codegen/plans/`
- **Feature Contexts** are archived in `{CURRENT_REPO}/codegen/contexts/`
- **Templates** are provided by the codegen tools

### Each Workspace Gets

- Git worktree with branch (`feature/{workspace-name}`)
- Docker container (`ocg-{workspace-name}`)
- Auto-assigned ports (Phoenix: 4001+, Playwright: 8901+)
- Database partition based on port offset
- Volume-mounted dependencies for fast startup
- Fresh copy of PROJECT_CONTEXT.md
- Claude Code integration with prepared prompts

## Commands

### Project Management

- `ocg setup` - Initialize project with PROJECT_CONTEXT.md (one-time)
- `ocg prepare` - Install Elixir/Erlang versions from .tool-versions (native mode)
- `ocg prepare --container` - Build Docker image and prepare base volumes
- `ocg update-context <name>` - Update project context with learnings from a feature
- `ocg consolidate-context` - Streamline PROJECT_CONTEXT.md by removing redundancies

### Planning Sessions

- `ocg bird-eye [name] [model]` - High-level, user-focused planning
- `ocg plan [name] [model]` - Detailed technical implementation planning

### Workspace Management

- `ocg new <name> [options]` - Create new feature workspace
  - `--model, -m <model>` - AI model to use (sonnet/opus, default: sonnet)
  - `--assistant, -a <name>` - AI assistant to use (claude/opencode, default: from config)
  - `--container` - Run in Docker container
- `ocg resume <name> [options]` - Resume existing workspace
  - `--model, -m <model>` - AI model to use (default: from workspace)
  - `--assistant, -a <name>` - AI assistant to use (default: from workspace)
  - `--container` - Run in Docker container
- `ocg rm <name>` - Remove workspace (stops container if applicable, archives context)
- `ocg ls` - List all workspaces

### AI Assistant Configuration

- `ocg ai-config set default <assistant>` - Set default AI assistant (claude/opencode)
- `ocg ai-config get default` - Show current default assistant
- `ocg ai-config status` - Show full AI assistant configuration

### Cleanup

- `ocg clean` - Remove ALL workspaces (with confirmation)
- `ocg clean-branches` - Remove orphaned feature branches
- `ocg clean-servers` - Clean up any lingering processes

### Tools

- `ocg remove-comments` - Remove comments from git diff changes
- `make install` - Install CLI globally for `ocg` commands
- `make uninstall` - Remove global CLI installation

## Global Installation

Install globally to use `ocg` commands from anywhere:

```bash
cd /path/to/codegen && make install
# Installs both Claude Code and OpenCode
# Prompts for default AI assistant preference
# Then use: ocg new my-feature, ocg ls, etc.
```

### AI Assistant Support

OCG supports both Claude Code and OpenCode as AI assistants:

- **Claude Code**: Official Anthropic CLI with rich terminal UI
- **OpenCode**: Open-source alternative with provider flexibility

During installation, both assistants are installed and you'll be prompted to choose a default. You can switch between them anytime:

```bash
# Set default assistant
ocg ai-config set default opencode

# Use specific assistant for a workspace
ocg new my-feature --assistant claude
ocg new my-feature -a opencode --model opus

# Check current configuration
ocg ai-config status
```

## Working with Docker

### Container Access

When a workspace is running in container mode, you can access the container:

```bash
# Open a terminal inside the container
docker exec -it ocg-{project-name}-{feature-name} /bin/bash

# Example for project "myapp" and feature "my-feature"
docker exec -it ocg-myapp-my-feature /bin/bash

# Run Phoenix server
docker exec -it ocg-myapp-my-feature mix phx.server

# Run tests
docker exec -it ocg-myapp-my-feature mix test
```

### Container Lifecycle

- Containers start automatically when you open a workspace in Cursor
- Containers stop when you close the startup terminal or press Ctrl+C
- Each workspace has its own container and volumes

### Volume Management

OCG uses Docker volumes for dependencies:

- Base volumes: `ocg-{project}-{deps|build|node}-base`
- Workspace volumes: `ocg-{project}-{deps|build|node}-{feature}`

Run `ocg prepare --container` from your main branch to build the Docker image and populate base volumes with compiled dependencies.

## Multiple Projects

The same codegen tools work with any git repository:

1. Navigate to any git repository
2. Run `ocg setup` to initialize project context (one-time)
3. Run `ocg prepare` or `ocg prepare --container` based on your preferred mode
4. Run `ocg` commands - they automatically manage workspaces for that repository
5. Each repository keeps its own:
   - Project context in `codegen/PROJECT_CONTEXT.md`
   - Workspaces in `codegen/workspaces/`
   - Plans in `codegen/plans/`
   - Archived contexts in `codegen/contexts/`
   - Docker volumes for dependencies

## Troubleshooting

### Docker Issues

- **"Docker daemon is not running"**: Start Docker Desktop
- **"Container failed to start"**: Check Docker logs with `docker logs ocg-{feature}`
- **Port conflicts**: OCG auto-assigns ports starting from 4001

### Workspace Issues

- **Dependencies missing**: Run `ocg prepare` (native) or `ocg prepare --container` from main branch
- **Old workspace won't start**: Remove and recreate with `ocg rm` then `ocg new`
- **Permission denied errors**: Ensure Docker Desktop is running before removing workspaces
