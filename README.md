# Optimum Codegen

A powerful workspace management system for Phoenix/Elixir projects that creates isolated feature workspaces using git worktrees and Docker containers.

## Overview

Optimum Codegen (OCG) is a workspace management system that enables parallel development of multiple features with separate environments, ports, and databases. Each workspace is an isolated git worktree with its own branch, Phoenix port, database partition, and optional Docker container.

## Harnesses

OCG supports multiple LLM harnesses (`claude`, `pi`). Each harness is declared in a single manifest file — the manifest is the single source of truth (SSoT) for launchers, agents, completions, system prompts, and install/uninstall steps.

| File                                        | Role                                                                     |
| ------------------------------------------- | ------------------------------------------------------------------------ |
| `harnesses/<h>/manifest.yaml`               | SSoT — full surface declaration                                          |
| `harnesses/<h>/tools-header/<mode>.txt`     | Per-harness system prompt content per mode                               |
| `harnesses/shared/prompt-bodies/<mode>.txt` | Shared system prompt body (common across harnesses)                      |
| `templates/generator/generate.sh`           | Unified generator (reads manifest, renders subagents, assembles prompts) |
| `templates/generator/manifest-lib.sh`       | Manifest helper library (sourced by generate.sh + install.sh)            |

`make install` drives the full generate → install flow. Adding or swapping a harness = drop one manifest + `make install`.

See **[docs/adding-a-harness.md](docs/adding-a-harness.md)** for the end-to-end guide: every manifest field, the generate/install flow, and how to add a new harness.

## Testing

Three Makefile targets, increasing cost:

| Target             | What it runs                                                                     | Cost                      | When                   |
| ------------------ | -------------------------------------------------------------------------------- | ------------------------- | ---------------------- |
| `make test`        | bash hook unit tests + `codegen-build_test.sh` + pi npm tests                    | seconds                   | every commit           |
| `make test-stacks` | ExUnit stack scaffold tests under `test_harness/` for both harnesses in parallel | minutes + real LLM tokens | before deploy          |
| `make test-all`    | `test` → `test-stacks` → writes `test_harness/last_green.json`                   | same as test-stacks       | weekly pre-deploy gate |

`make test` is bash-only and runs without Elixir installed. `make test-stacks` requires Elixir 1.15+.

`test_harness/last_green.json` records the codegen sha + harness versions + timestamp of the last green `make test-all` run. It is committed in this repo and consumed by downstream pin tooling (e.g., `mix combobulate.codegen.pin`).

## Prerequisites

- Docker Desktop installed and running (for container mode)
- Git (`brew install git` / system package manager)
- Cursor IDE (recommended) or VS Code
- Phoenix/Elixir project
- mise — tool version manager (`curl https://mise.run | sh`)
- python3 + pyyaml (`pip3 install --user pyyaml`) — required by generator pipeline
- jq — JSON processor (`brew install jq`)
- yq — YAML processor, **mikefarah/yq required** (`brew install yq` on macOS; `apt python-yq` is **incompatible** — install from https://github.com/mikefarah/yq)
- ripgrep/rg (`brew install ripgrep`)
- node — required for ajv/playwright hook verification (install via mise: `mise install node`)
- AI Assistant: Claude Code (installed automatically by `make install`)
- AI Assistant: Pi (install manually: `npm install -g @earendil-works/pi-coding-agent`; `make install` configures `~/.pi/agent/` but does NOT install the binary)

## Configuration

The system automatically detects which git repository you're currently in and manages workspaces for that repository.

### Optional: Set OCG Context Directory

For advanced users who want to share rules and recipes across projects:

```bash
# Set the context directory (optional)
export OCG_CONTEXT_DIR=~/path/to/your/context

# This enables automatic linking of shared rules and recipes during project setup
# If not set, you can manually create symlinks as needed
```

Otherwise, no configuration needed!

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
│   ├── FIGMA_DESIGN_SYSTEM_RULES.md  # Figma design system rules and guidelines
│   ├── FIGMA_TOKEN_MAPPING.md  # Figma design token mappings
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
- Fresh copy of PROJECT_CONTEXT.md and Figma design files (FIGMA_MAP.md, FIGMA_DESIGN_SYSTEM_RULES.md, FIGMA_TOKEN_MAPPING.md)
- Claude Code integration with prepared prompts

## Commands Reference

### Project Management

- `ocg setup [options]` - Initialize project with PROJECT_CONTEXT.md (one-time)
  - `--model, -m <model>` - AI model to use (haiku/sonnet/opus, default: opus)
  - `--agent, -a <name>` - AI agent to use (default: from config)
- `ocg prepare` - Install Elixir/Erlang versions from .tool-versions (native mode)
- `ocg prepare --container` - Build Docker image and prepare base volumes
- `ocg update-context <name>` - Update project context with learnings from a feature
- `ocg consolidate-context` - Streamline PROJECT_CONTEXT.md by removing redundancies

### Planning Sessions

- `ocg bird-eye [name] [model]` - High-level, user-focused planning (default model: opus)
- `ocg plan [name] [model]` - Detailed technical implementation planning (default model: opus)

### Workspace Management

- `ocg new <name> [options]` - Create new feature workspace
  - `--model, -m <model>` - AI model to use (haiku/sonnet/opus, default: sonnet)
  - `--agent, -a <name>` - AI agent to use (claude/pi, default: from config)
  - `--container` - Run in Docker container
- `ocg resume <name> [options]` - Resume existing workspace
  - `--model, -m <model>` - AI model to use (default: from workspace)
  - `--agent, -a <name>` - AI agent to use (default: from workspace)
  - `--container` - Run in Docker container
- `ocg rm <name>` - Remove workspace (stops container if applicable, archives context)
- `ocg ls` - List all workspaces

### AI Agent Configuration

- `ocg ai-config set default <agent>` - Set default AI agent (claude/pi)
- `ocg ai-config get default` - Show current default agent
- `ocg ai-config status` - Show full AI agent configuration

### Cleanup

- `ocg clean` - Remove ALL workspaces (with confirmation)
- `ocg clean-branches` - Remove orphaned feature branches
- `ocg clean-servers` - Clean up any lingering processes
- `ocg resources [--cleanup-orphaned]` - Show global resource allocation across all projects

### Tools

- `ocg usage-rules [options]` - Generate usage rules for Elixir dependencies from mix.exs
  - `--model, -m <model>` - AI model to use (haiku/sonnet/opus, default: haiku)
  - `--agent, -a <name>` - AI agent to use (claude/pi, default: from config)
  - `--help` - Show usage information
- `ocg remove-comments` - Remove comments from git diff changes
- `ocg format` - Format all shell scripts and files
- `ocg update` - Update all AI agents (Claude Code)
- `ocg uninstall` - Remove global CLI installation
- `make install` - Install CLI globally for `ocg` commands (run from codegen directory)

### Phoenix/Elixir Commands (within workspaces)

- `mix setup` - Install dependencies, setup database, build assets
- `mix phx.server` - Start Phoenix server
- `mix deps.get` - Install Elixir dependencies
- `mix test` - Run tests
- `mix test path/to/test.exs` - Run single test file

## Development Workflow

### Recommended Planning-First Workflow

1. **Initialize Project**: Run `ocg setup` once per repository
2. **Generate Usage Rules**: Run `ocg usage-rules` to create AI-readable dependency documentation
3. **Bird-Eye Planning**: Run `ocg bird-eye {feature}` for high-level planning
4. **Detailed Planning**: Run `ocg plan {feature}` for technical planning
5. **Create Workspace**: Run `ocg new {feature}` - automatically:
   - Creates git worktree with your plan
   - Assigns ports
   - Copies dependencies from main
   - Opens IDE with context
   - Starts servers
6. **Develop**: Work in isolated environment with AI assistance
7. **Archive**: Run `ocg rm {feature}` to save context
8. **Update Knowledge**: Run `ocg update-context {feature}` to incorporate learnings
9. **Cleanup**: Use `ocg clean-branches` when features are merged

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
# Installs Claude Code
# Prompts for default AI agent preference
# Then use: ocg new my-feature, ocg ls, etc.
```

### AI Agent Support

OCG supports two AI agents:

- **Claude Code**: Official Anthropic CLI with rich terminal UI
- **Pi**: Pi CLI agent

During installation, both agents are installed and you'll be prompted to choose a default. You can switch between them anytime:

```bash
# Set default agent
ocg ai-config set default pi

# Use specific agent for a workspace
ocg new my-feature --agent claude
ocg new my-feature -a pi --model opus

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

- **haiku** - Fastest, most cost-effective for straightforward tasks
- **sonnet** - Balanced performance, good for implementation and development tasks
- **opus** - Most thorough analysis, best for planning and complex reasoning

### Default Models by Command

- **`init`**: opus (comprehensive project setup and analysis)
- **`setup`**: opus (comprehensive project analysis)
- **`bird-eye`**: opus (high-level planning requiring deep thinking)
- **`plan`**: opus (detailed technical planning)
- **`new`/`resume`**: sonnet (balanced for implementation work)
- **`usage-rules`**: haiku (fast and cost-effective documentation extraction)
- **`update-context`**: sonnet (routine context updates)
- **`consolidate-context`**: opus (thorough consolidation for clarity)

**Note**: While Opus 4.1 is currently weaker than Sonnet 4.5, the defaults are set for when Opus 4.5 is released. Use `--model sonnet` to override for now if needed.

## Important Conventions

### Git Workflow

- Feature branches use pattern: `feature/{name}`
- Workspaces are git worktrees, not clones
- Main branch artifacts (deps, \_build) are copied to speed setup
- Branches are preserved after workspace removal unless explicitly cleaned

### Port Management

- Phoenix ports start at 4001 and increment by 1
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

### Usage Rules

- AI-readable documentation for Elixir dependencies generated from hexdocs
- Usage rules are stored in `~/Areas/Optimum/context/usage_rules/`
- Generated automatically by parsing mix.exs and fetching documentation
- Provides practical examples, configuration, and best practices for each library
- Run `ocg usage-rules` from any Elixir project to generate missing rules

### AI Integration

- IDE automatically opens with feature context
- MCP servers provide additional tooling (Tidewave for Elixir)
- Playwright CLI available for visual testing via `npx playwright screenshot`
- Context files guide AI agents through development stages
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
