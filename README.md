# Optimum Codegen

A powerful workspace management system for Phoenix/Elixir projects that creates isolated feature workspaces using git worktrees.

## Configuration

The system automatically detects which git repository you're currently in and manages workspaces for that repository. No configuration needed!

## Quick Start

1. **Navigate to your project repository**
2. **Create a new feature workspace:**
   ```bash
   ocg new my-feature
   ```
3. **List all workspaces:**
   ```bash
   ocg ls
   ```
4. **Resume an existing workspace:**
   ```bash
   ocg resume my-feature
   ```

## How It Works

- **Workspaces** are created in `{CURRENT_REPO}/codegen/workspaces/`
- **Plans** are stored in `{CURRENT_REPO}/codegen/plans/`
- **Templates** are provided by the codegen tools
- Each workspace gets its own:
  - Git branch (`feature/{workspace-name}`)
  - Port (auto-assigned starting from 4001)
  - Database partition
  - Playwright MCP server port

## Commands

- `ocg new <name>` - Create new feature workspace
- `ocg resume <name>` - Resume existing workspace
- `ocg rm <name>` - Remove feature workspace
- `ocg clean` - Remove ALL workspaces (with confirmation)
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
2. Run `ocg` commands - they automatically manage workspaces for that repository
3. Each repository keeps its own workspaces and plans in `codegen/workspaces/` and `codegen/plans/`
