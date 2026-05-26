# credo

Static analysis tool for Elixir code that identifies quality, consistency, and readability issues through a flexible check system and configurable pipeline.

## Quick Start

**Installation**: Add to `mix.exs` dependencies:

```elixir
{:credo, "~> 1.7", only: [:dev, :test]}
```

**Basic Usage**:

```bash
mix credo                    # Run all checks on the codebase
mix credo --only Readability # Run only readability checks
mix credo --only Consistency # Run only consistency checks
mix credo --strict           # Strict mode, fails on any issue
mix credo --help             # View all available options
```

## Core Concepts

**Check Categories**: Credo organizes checks into five categories:

- **Consistency** — Code uniformity across files and conventions
- **Design** — Architectural patterns and dependencies
- **Readability** — Code clarity and understandability
- **Refactor** — Improvement opportunities without changing behavior
- **Warning** — Potential bugs and problematic patterns

**Check Priority Levels**: Each check has a base priority:

- `:low` — Minor style suggestions
- `:normal` — Standard quality checks
- `:high` — Important code issues
- `:higher` — Critical problems
- `:ignore` — Disabled by default

**Execution Pipeline**: Credo runs as an Execution struct that:

1. Builds from CLI arguments (`Credo.Execution.build/1`)
2. Loads configured checks
3. Processes source files through check pipeline
4. Collects and formats issues
5. Reports results with exit status

**Core Functions**:

- `Credo.run(args)` — Execute analysis with arguments, returns Execution struct
- `Credo.Execution.get_issues(exec)` — Retrieve identified issues
- `Credo.Execution.get_source_files(exec)` — List analyzed files
- `Credo.Execution.checks(exec)` — Get active checks after filtering

## Configuration

**Default Config File**: `.credo.exs` in project root

**Check Configuration**:

```elixir
checks: [
  {Credo.Check.Consistency.LineLength, [max_length: 120]},
  {Credo.Check.Design.AliasUsage, []},
  {Credo.Check.Readability.Specs, [enabled: true]},
]
```

**Check Options**:

- `:base_priority` — Priority level (`:ignore` disables)
- `:category` — Assigns check category
- `:enabled` — Boolean to enable/disable
- `:param_defaults` — Default parameter values
- `:tags` — List of atoms for organization
- `:elixir_version` — Minimum Elixir version
- `:explanations` — Documentation for check purpose and params

**File/Folder Filtering**:

```elixir
include: ["lib/", "test/"],
exclude: ["node_modules", ".git"],
strict: false,
parse_timeout: 5000,
```

## Best Practices

**1. Configure for Project Standards**: Tailor checks to match team conventions. Disable checks that conflict with your style (e.g., line length preferences).

**2. Use Categories Strategically**: Run specific categories in different contexts:

- CI gates: all checks in strict mode
- Pre-commit: consistency and warning only
- Design reviews: design category focus

**3. Incremental Adoption**: Start with `:high` and `:higher` priorities, gradually enable lower priorities as team consensus builds.

**4. Exclude Generated Code**: Always exclude directories with generated files (e.g., `node_modules`, build artifacts).

**5. Version Constraints**: Set `:elixir_version` in checks to prevent false positives on code written for different versions.

**6. Strict Mode for CI**: Use `--strict` flag in CI pipelines to fail on any issue, ensuring code quality gates.

**7. Custom Checks**: Create domain-specific checks by implementing `Credo.Check` behavior with `run/2` callback:

```elixir
defmodule MyProject.Checks.MyCheck do
  use Credo.Check, category: :consistency

  def run(source_file, params) do
    # Return list of issues found
  end
end
```

**8. Parse Timeout**: Increase `:parse_timeout` if analysis stalls on large codebases (default: 5000ms).

---

**Version:** 1.7.17
**Source:** https://hexdocs.pm/credo/
**Generated:** 2026-04-25
