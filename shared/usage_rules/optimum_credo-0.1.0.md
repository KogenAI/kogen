# optimum_credo

OptimumCredo is an Elixir package that provides custom code quality checks for the Credo linter. It implements readability-focused checks to enforce consistent code style and organization standards across Elixir projects.

## Quick Start

### Installation

Add OptimumCredo as a test-only dependency in `mix.exs`:

```elixir
def deps do
  [
    {:optimum_credo, "~> 0.1", only: :test, runtime: false}
  ]
end
```

Run `mix deps.get` to install the package.

### Basic Configuration

Enable checks in `.credo.exs` by adding them to your checks list:

```elixir
# .credo.exs
{
  configs: [
    %{
      name: "default",
      checks: [
        # ... other Credo checks ...
        {OptimumCredo.Check.Readability.ImportOrder, []},
        {OptimumCredo.Check.Readability.DepsOrder, []},
        {OptimumCredo.Check.Readability.TypespecOrder, []}
      ]
    }
  ]
}
```

### Running Checks

Execute Credo normally:

```bash
mix credo
```

OptimumCredo checks will run alongside standard Credo checks.

## Core Concepts

### Available Checks

OptimumCredo provides three readability-focused checks:

#### 1. ImportOrder

Enforces alphabetical ordering of import statements for improved code scannability.

- **Purpose**: Consistent import organization reduces cognitive load and improves maintainability
- **Default behavior**: Disabled (low priority)
- **Scope**: All import statements in modules
- **Benefits**: Faster code review, easier dependency tracking

#### 2. DepsOrder

Validates alphabetical ordering of dependencies within dependency groups.

- **Validates ordering in**: `app_deps`, `optimum_deps` groups
- **Purpose**: Alphabetically ordered dependencies are more easily scannable by readers
- **Default behavior**: Disabled (low priority)
- **Scope**: `mix.exs` dependency declarations
- **Benefits**: Consistent project structure, cleaner mix file organization

#### 3. TypespecOrder

Maintains consistent ordering of typespec declarations.

- **Purpose**: Organized type definitions improve code readability
- **Default behavior**: Disabled (low priority)
- **Scope**: Typespec and type declarations in modules
- **Benefits**: Better type visibility, cleaner module structure

### Sorting Methods

All checks support two sorting approaches via the `:sort_method` parameter:

- **`:alpha`** (default) - Case-insensitive alphabetical sorting (example: `Auth` and `auth` treated as equivalent)
- **`:ascii`** - Case-sensitive sorting where uppercase precedes lowercase (standard ASCII ordering)

## Configuration

### Check Parameters

Each check accepts a keyword list of options:

```elixir
# Default configuration (case-insensitive alphabetical sorting)
{OptimumCredo.Check.Readability.ImportOrder, []}

# Custom sort method (case-sensitive)
{OptimumCredo.Check.Readability.ImportOrder, [sort_method: :ascii]}

# Apply to specific DepsOrder function groups
{OptimumCredo.Check.Readability.DepsOrder, [sort_method: :alpha]}
```

### Enabling/Disabling Checks

- **All checks are disabled by default** - add them to `.credo.exs` to enable
- **Disable specific checks**: Remove from `.credo.exs` or wrap in condition
- **Override priority**: Use Credo's configuration system to adjust priority

## Best Practices

### Import Organization Strategy

1. **Group related imports together**: Keep domain-specific imports close together
2. **Use consistent alphabetical ordering**: Within each group, maintain alphabetical order
3. **Leverage Credo for enforcement**: Let OptimumCredo checks catch ordering violations during CI/CD
4. **Document import groups**: Add comments before logical groupings for clarity

Example of well-organized imports:

```elixir
defmodule MyApp.Service do
  # Standard library
  import Enum
  import Keyword
  import List

  # Phoenix framework
  import Phoenix.Component
  import Phoenix.LiveView

  # Application code
  import MyApp.Constants
  import MyApp.Helpers
end
```

### Dependency Organization

1. **Keep dependencies alphabetically ordered in each group**: Improves scannability in code reviews
2. **Use meaningful group names**: `app_deps`, `optimum_deps` clearly indicate purpose
3. **Review during mix.exs maintenance**: When adding/updating dependencies, check ordering
4. **Let CI enforce ordering**: OptimumCredo catches violations automatically

### Integration with Development Workflow

- **Local development**: Run `mix credo` before committing to catch style issues
- **CI/CD pipeline**: Include Credo checks in pipeline to enforce standards
- **Team consistency**: Document sorting method choice (`:alpha` or `:ascii`) in project docs
- **Gradual adoption**: Enable checks incrementally to avoid overwhelming developers

### Type Declaration Ordering

- **Group related types**: Keep closely-related typespecs together
- **Document typespec dependencies**: When order matters, add comments explaining relationships
- **Maintain consistency**: Use same ordering strategy across all modules

---

**Version:** 0.1.0
**Source:** [hexdocs.pm/optimum_credo](https://hexdocs.pm/optimum_credo/)
**Generated:** 2025-10-28
