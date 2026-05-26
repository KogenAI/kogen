# credo

Credo is a static code analysis tool for Elixir with a focus on teaching and code consistency. It identifies refactoring opportunities, detects complex code fragments, warns about common mistakes, and enforces coding style standards across your codebase.

## Quick Start

**Installation**: Add to `mix.exs` dependencies (dev only):

```elixir
{:credo, "~> 1.7", only: [:dev, :test]}
```

**Basic Usage**:

```bash
mix credo              # Run analysis with priority filtering
mix credo --all        # Show all issues
mix credo --strict     # Include low-priority issues
```

**Understanding Issues**: Get detailed explanation for a specific issue:

```bash
mix credo lib/foo/bar.ex:306
mix credo lib/foo/bar.ex:306 --format json
```

## Core Concepts

### Checks & Categories

Credo ships with 60+ built-in checks organized into five categories:

| Category       | Purpose                         | Exit Code |
| -------------- | ------------------------------- | --------- |
| `:consistency` | Naming and code patterns        | 1         |
| `:design`      | Code structure and organization | 2         |
| `:readability` | Code clarity and simplicity     | 4         |
| `:refactor`    | Improvement opportunities       | 8         |
| `:warning`     | Error-prone patterns            | 16        |

### Priority Levels

Checks have priority levels (`:low`, `:normal`, `:high`, `:higher`) controlling which issues display by default:

- Default mode shows higher-priority issues (↑ ↗ →)
- `--strict` flag includes all priorities
- Per-check priority override via configuration

### Exit Status Mapping

Credo's exit status reflects issue categories found (bitwise OR):

- 0: No issues
- 1: Consistency issues only
- 3: Consistency + design
- 7: Consistency + design + readability
- 31: All categories

## Configuration

**File Location**: `.credo.exs` in project root or `config/` directory
**Generation**: `mix credo gen.config`

### Structure

```elixir
%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "test/"],
        excluded: ["lib/generated/"]
      },
      checks: %{
        enabled: [...],
        disabled: [...],
        extra: [...]
      },
      color: true,
      parse_timeout: 5000,
      plugins: [],
      requires: [],
      strict: false
    }
  ]
}
```

### Configuration Keys

- **`:name`** – Config identifier (e.g., "default", "strict")
- **`:files`** – File/directory inclusion/exclusion patterns
- **`:checks`** – Control which checks run (see below)
- **`:color`** – Toggle colored output (default: true)
- **`:parse_timeout`** – File parsing timeout in ms (default: 5000)
- **`:plugins`** – Load plugin modules for extensions
- **`:requires`** – Source Elixir files for custom checks
- **`:strict`** – Enable all priority levels by default

### Check Configuration Methods

**Enabled-only approach** (runs specified checks exclusively):

```elixir
checks: %{
  enabled: [
    {Credo.Check.Consistency.TabsOrSpaces},
    {Credo.Check.Readability.FunctionNames}
  ]
}
```

**Disabled approach** (disable specific checks while using defaults):

```elixir
checks: %{
  disabled: [
    {Credo.Check.Warning.IExPry},
    {Credo.Check.Readability.BlockDeviation}
  ]
}
```

**Extra approach** (augment or override defaults):

```elixir
checks: %{
  extra: [
    {MyApp.CustomCheck, param: "value"}
  ]
}
```

### Check Parameters

Each check is a tuple `{ModuleName, params}` where params is `false` (disable) or a keyword list:

```elixir
{Credo.Check.Readability.MaxLineLength, max_length: 120}
{Credo.Check.Warning.IExPry, priority: :low}
{Credo.Check.Refactor.CyclomaticComplexity, max_complexity: 12}
```

**Universal Parameters**:

- **`:category`** – Override check's category assignment
- **`:exit_status`** – Custom exit code for the check (0 to suppress failures)
- **`:files`** – Per-check file patterns (include/exclude)
- **`:priority`** – Importance level (`:low`, `:normal`, `:high`, `:higher`)
- **`:tags`** – Labels for selective execution (see filtering below)

### Multi-Configuration Support

Define multiple named configs for different contexts:

```elixir
configs: [
  %{name: "default", checks: [...]},
  %{name: "strict", strict: true, checks: [...]}
]
```

Run alternative configs:

```bash
mix credo --config-name strict
```

### Transitive Configuration

Credo merges `.credo.exs` files from parent directories upward, enabling umbrella projects to maintain both global and per-app configurations.

## Best Practices

### Command-Line Filtering

```bash
mix credo --only Readability              # Run only readability checks
mix credo --only Consistency,Design       # Multiple categories
mix credo --checks-with-tag my_tag        # Custom tag filtering
mix credo --checks-without-tag debug      # Exclude by tag
mix credo lib/                            # Analyze specific path
```

### Integration in CI/CD

Use exit status to gate deployments:

```bash
mix credo --strict
if [ $? -eq 0 ]; then deploy; fi
```

### Custom Checks

Register custom checks in `.credo.exs`:

```elixir
%{
  requires: ["lib/my_credo_checks.ex"],
  checks: %{
    extra: [{MyApp.MyCustomCheck, param: "value"}]
  }
}
```

Custom check minimum structure:

```elixir
defmodule MyApp.MyCustomCheck do
  use Credo.Check,
    base_priority: :high,
    category: :readability,
    explanation: "This check detects...",
    param_defaults: [max_length: 80]

  def run(source_file, params) do
    # Return list of Credo.Issue structs
  end
end
```

### Handling Exceptions

Suppress Credo in specific files:

```elixir
# credo:disable-for-this-file
defmodule Generated.Code do
  # ...
end
```

Suppress within a scope:

```elixir
# credo:disable-for-next-line Credo.Check.Design.LargeDefaults
def function(arg1 \\ default1, arg2 \\ default2) do
  # ...
end
```

### View Available Checks

```bash
mix credo info                    # Active checks
mix credo info --verbose          # Detailed check info
mix credo explain Readability     # Category documentation
mix credo explain Credo.Check.X   # Specific check details
```

### Performance Optimization

- Set reasonable `:parse_timeout` for large codebases
- Use `:files` exclusions to skip generated code, dependencies
- Run specific categories when developing: `mix credo --only Readability`

---

**Version:** 1.7.18
**Source:** [hexdocs.pm/credo](https://hexdocs.pm/credo/)
**Generated:** 2026-05-09
