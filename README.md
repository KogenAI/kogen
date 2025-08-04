# Optimum Codegen

A powerful workspace management system for Phoenix/Elixir projects that creates isolated feature workspaces using git worktrees and Docker containers.

## Overview

Optimum Codegen (OCG) is a workspace management system that enables parallel development of multiple features with separate environments, ports, and databases. Each workspace is an isolated git worktree with its own branch, Phoenix port, database partition, and optional Docker container.

## Prerequisites

- Docker Desktop installed and running (for container mode)
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

```
{TARGET_REPO}/
├── codegen/
│   ├── PROJECT_CONTEXT.md      # Main project knowledge base
│   ├── FIGMA_MAP.md            # Figma node ID to Phoenix component mapping
│   ├── workspaces/             # Isolated feature workspaces
│   │   └── {feature}/          # Git worktree for feature
│   ├── plans/                  # Feature development plans
│   │   ├── {feature}/          # Modular plan structure
│   │   │   ├── overview.md     # Goals, architecture, step sequence
│   │   │   └── steps/          # Detailed step implementations
│   │   └── {feature}.md        # Legacy single-file plan
│   └── contexts/               # Archived feature contexts
│       └── {feature}/          # Context files after completion
```

### Each Workspace Gets

- Git worktree with branch (`feature/{workspace-name}`)
- Docker container (`ocg-{workspace-name}`) if using container mode
- Auto-assigned ports (Phoenix: 4001+, Playwright: 8901+)
- Database partition based on port offset
- Volume-mounted dependencies for fast startup
- Fresh copy of PROJECT_CONTEXT.md and FIGMA_MAP.md
- Claude Code integration with prepared prompts

## Commands Reference

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
- `ocg resources [--cleanup-orphaned]` - Show global resource allocation across all projects

### Tools

- `ocg remove-comments` - Remove comments from git diff changes
- `ocg format` - Format all shell scripts and files
- `make install` - Install CLI globally for `ocg` commands
- `make uninstall` - Remove global CLI installation

### Phoenix/Elixir Commands (within workspaces)

- `mix setup` - Install dependencies, setup database, build assets
- `mix phx.server` - Start Phoenix server
- `mix deps.get` - Install Elixir dependencies
- `mix test` - Run tests
- `mix test path/to/test.exs` - Run single test file

## Development Workflow

### Recommended Planning-First Workflow

1. **Initialize Project**: Run `ocg setup` once per repository
2. **Bird-Eye Planning**: Run `ocg bird-eye {feature}` for high-level planning
3. **Detailed Planning**: Run `ocg plan {feature}` for technical planning
4. **Create Workspace**: Run `ocg new {feature}` - automatically:
   - Creates git worktree with your plan
   - Assigns ports
   - Copies dependencies from main
   - Opens IDE with context
   - Starts servers
5. **Develop**: Work in isolated environment with AI assistance
6. **Archive**: Run `ocg rm {feature}` to save context
7. **Update Knowledge**: Run `ocg update-context {feature}` to incorporate learnings
8. **Cleanup**: Use `ocg clean-branches` when features are merged

### Container vs Native Modes

**Native Mode** (default)

- Workspaces run directly on your host system
- Uses your existing Elixir/Phoenix installation
- Fast startup, direct file access
- Example: `ocg new my-feature`

**Container Mode** (`--container` flag)

- Workspaces run in isolated Docker containers
- Consistent Elixir/Phoenix environment across machines
- Isolated authentication and dependencies
- Example: `ocg new my-feature --container`

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

## Context Window Management

### File Size Guidelines

To optimize context window usage, maintain these target sizes:

- **PROJECT_CONTEXT.md**: 150-250 lines (use `ocg consolidate-context` when larger)
- **Plan overview**: 50-100 lines (overview.md created by `ocg plan`)
- **Plan steps**: 150-250 lines each (step files for detailed implementation)
- **CONTEXT.md**: 50-100 lines (detailed step progress in codegen/context/)
- **Total during implementation**: ~250-400 lines (overview + current step + context), leaving ample room for code reading

### Consolidation Best Practices

- **Clarity over brevity**: Expand cryptic one-liners into clear explanations
- **Remove feature sections**: Integrate learnings into relevant sections, not changelog-style lists
- **Focus on actionable knowledge**: Patterns, pitfalls, and approaches that help future development
- **Quality threshold**: 250 clear lines is better than 150 cryptic lines

### Context Commands

- Use `/refresh-context` command (if available) to archive completed work
- Focus on removing completed implementation details while preserving learnings
- Run `ocg consolidate-context` when PROJECT_CONTEXT.md exceeds 250 lines

## Model Selection Guidelines

- **sonnet** - Faster responses, good for implementation and development tasks
- **opus** - More thorough analysis, better for planning and complex reasoning
- **Default usage**:
  - `bird-eye`: opus (high-level planning)
  - `plan`: opus (detailed technical planning)
  - `new`/`resume`: sonnet (implementation work)
  - `setup`: opus (comprehensive project analysis)
  - `update-context`: sonnet (routine context updates)
  - `consolidate-context`: opus (thorough consolidation for clarity)

## Important Conventions

### Git Workflow

- Feature branches use pattern: `feature/{name}`
- Workspaces are git worktrees, not clones
- Main branch artifacts (deps, \_build) are copied to speed setup
- Branches are preserved after workspace removal unless explicitly cleaned

### Port Management

- Phoenix ports start at 4001 and increment by 1
- Playwright MCP ports start at 8901 and increment by 1
- Ports are automatically assigned based on existing workspaces
- Server cleanup is automatic before starting new servers

### Context Management

- PROJECT_CONTEXT.md is the source of truth for project knowledge (target: 150-250 lines)
- Each workspace gets a fresh copy of PROJECT_CONTEXT.md
- Feature contexts are archived in `codegen/contexts/{feature}/`
- Use `ocg update-context` to merge learnings back to main context (integrates, not appends)
- Use `ocg consolidate-context` to streamline PROJECT_CONTEXT.md when it exceeds 250 lines
- Avoid changelog-style feature sections - integrate learnings into existing structure

### Recipe Extraction

- Reusable patterns are automatically extracted during `ocg update-context`
- Recipes are stored in `~/Areas/Optimum/context/recipes/`
- Each recipe documents a self-contained, reusable technique
- Examples: data sanitization, auth patterns, testing strategies

### AI Integration

- IDE automatically opens with feature context
- MCP servers provide additional tooling (Tidewave for Elixir, Playwright for browser)
- Context files guide AI assistants through development stages
- Model selection optimizes AI assistance for different task types

## Context Quality Guidelines

- **Module Names**: Always preserve full module names for Tidewave/MCP compatibility
- **Pattern Descriptions**: Explain patterns clearly (e.g., "Context functions delegate to sub-modules" not "API → sub-modules")
- **Feature Learnings**: Integrate into relevant sections, not separate changelog sections
- **Pitfalls**: Document with specific solutions (e.g., "Use User.job_seeker?/1 helpers")
- **Size vs Clarity**: Prioritize clarity - 250 clear lines > 150 cryptic lines

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

## Security Notes

- Never commit .env files (already in .gitignore)
- Database credentials use development defaults
- Each workspace has isolated database partition
- No production credentials should be stored in workspaces

## Bash Completion

- Bash completion is available for all commands and arguments
- Automatically completes feature names, workspace names, and model parameters
- Source `bash_completion.sh` or install globally with `make install`

## Troubleshooting

### Docker Issues

- **"Docker daemon is not running"**: Start Docker Desktop
- **"Container failed to start"**: Check Docker logs with `docker logs ocg-{feature}`
- **Port conflicts**: OCG auto-assigns ports starting from 4001

### Workspace Issues

- **Dependencies missing**: Run `ocg prepare` (native) or `ocg prepare --container` from main branch
- **Old workspace won't start**: Remove and recreate with `ocg rm` then `ocg new`
- **Permission denied errors**: Ensure Docker Desktop is running before removing workspaces
