# Optimum Codegen

A powerful workspace management system for Phoenix/Elixir projects that creates isolated feature workspaces using git worktrees.

## Configuration

The system automatically detects which git repository you're currently in and manages workspaces for that repository. No configuration needed!

## Quick Start

1. **Navigate to your project repository**
2. **Initialize project context (one-time setup):**
   ```bash
   ocg setup
   ```
3. **Create a new feature workspace:**
   ```bash
   ocg new my-feature
   ```
4. **List all workspaces:**
   ```bash
   ocg ls
   ```
5. **Resume an existing workspace:**
   ```bash
   ocg resume my-feature
   ```

## How It Works

- **Project Context** is stored in `{CURRENT_REPO}/codegen/PROJECT_CONTEXT.md`
- **Workspaces** are created in `{CURRENT_REPO}/codegen/workspaces/`
- **Plans** are stored in `{CURRENT_REPO}/codegen/plans/`
- **Feature Contexts** are archived in `{CURRENT_REPO}/codegen/contexts/`
- **Templates** are provided by the codegen tools
- Each workspace gets its own:
  - Git branch (`feature/{workspace-name}`)
  - Port (auto-assigned starting from 4001)
  - Database partition
  - Playwright MCP server port
  - Fresh copy of PROJECT_CONTEXT.md

## Commands

- `ocg setup` - Initialize project with PROJECT_CONTEXT.md (one-time)
- `ocg update-context <name>` - Update project context for a specific feature
- `ocg new <name>` - Create new feature workspace
- `ocg resume <name>` - Resume existing workspace
- `ocg rm <name>` - Remove feature workspace
- `ocg clean` - Remove ALL workspaces (with confirmation)
- `ocg clean-branches` - Remove all orphaned feature branches (with confirmation)
- `ocg clean-servers` - Kill all Playwright MCP and Phoenix servers
- `ocg ls` - List all workspaces
- `make install` - Install CLI globally (`ocg` commands)

## Global Installation

Install globally to use `ocg` commands from anywhere:

```bash
cd /path/to/codegen && make install
# Then use: ocg new my-feature, ocg ls, etc.
```

## Multiple Projects

The same codegen tools work with any git repository:

1. Navigate to any git repository
2. Run `ocg setup` to initialize project context (one-time)
3. Run `ocg` commands - they automatically manage workspaces for that repository
4. Each repository keeps its own:
   - Project context in `codegen/PROJECT_CONTEXT.md`
   - Workspaces in `codegen/workspaces/`
   - Plans in `codegen/plans/`
   - Archived contexts in `codegen/contexts/`
