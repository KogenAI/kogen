# credo

Credo is a static code analysis tool for Elixir that checks for common mistakes, enforces code style, and refactoring opportunities. It's designed as a linter and code quality checker integrated into the development workflow.

## Quick Start

### Installation

Add Credo to your `mix.exs` as a development dependency:

```elixir
defp deps do
  [
    {:credo, "~> 1.7", only: [:dev, :test]}
  ]
end
```

Then run:

```bash
mix deps.get
mix credo
```

### Basic Usage

Run Credo on your project:

```bash
# Check all files in lib/
mix credo

# Check a specific file or directory
mix credo lib/my_app/user.ex

# Show more details
mix credo --strict

# Show detailed explanations
mix credo explain

# List all available checks
mix credo list
```

## Core Concepts

### Check Categories

Credo organizes checks into categories:

- **Consistency** - Code style and consistency issues (naming, line length, formatting)
- **Readability** - Code that is harder to understand (complex functions, unused variables)
- **Refactoring Opportunities** - Code that could be simplified or improved
- **Warnings** - Potential bugs or deprecated patterns
- **Design** - Architectural concerns (module complexity, parameter count)

### Priority Levels

Each issue is assigned a priority (1-10):

- **High priority (>= 10)** - Likely bugs or critical style violations
- **Medium priority** - Code quality issues worth addressing
- **Low priority** - Suggestions for improvement

### Exit Codes

- `0` - No issues found
- `1` - Issues found but within tolerance
- `2` - Issues exceed configured threshold (strict mode)

## Configuration

Create a `.credo.exs` file in your project root to customize Credo behavior:

```elixir
%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "test/"],
        excluded: ["lib/legacy/"]
      },
      checks: [
        # Disable specific checks
        {Credo.Check.Consistency.LineLength, false},

        # Configure check parameters
        {Credo.Check.Design.AliasUsage, [priority: :low]},
        {Credo.Check.Consistency.ParameterPatternMatching, [max_params: 4]}
      ],
      strict: true
    }
  ]
}
```

### Configuration Options

- **files.included** - Patterns for files to check (defaults: `["lib/", "src/"]`)
- **files.excluded** - Patterns for files to skip (e.g., migrations, generated code)
- **checks** - List of checks to enable/disable and their parameters
- **strict** - Fail if any issues found (default: false)
- **parse_timeout** - Timeout for parsing files in milliseconds
- **max_concurrent_checks** - Number of parallel check processes

### Disabling Checks Inline

Disable a check for a specific module, function, or line:

```elixir
# Disable for entire module
@credo :disable_for_this_file

# Disable specific check
# credo:disable-for-lines:2 Credo.Check.Readability.LargeNumbers
def my_function do
  1_000_000
end

# Disable for next line
defmodule MyModule do  # credo:disable-for-next-line Credo.Check.Consistency.MixedCaseAndUnderscores
  defmodule nested do
  end
end
```

## Best Practices

### Integration into Development Workflow

1. **Run before committing**: Use a git pre-commit hook to catch issues early
2. **CI/CD integration**: Add `mix credo --strict` to your CI pipeline
3. **Gradual adoption**: Start with warnings only, gradually enable stricter checks
4. **Team alignment**: Commit `.credo.exs` to version control for consistent team standards

### Common Patterns

#### Checking Only Changed Files

Create a mix task or script to check only modified files:

```bash
mix credo lib/ --only-checks DuplicatedCode
```

#### Formatting + Linting

Combine with `mix format`:

```bash
mix format  # Auto-fix style issues
mix credo   # Check for logic and design issues
```

#### Ignoring Generated Code

```elixir
files: %{
  included: ["lib/"],
  excluded: [~r"lib/.*_generated\.ex$"]
}
```

### Common Pitfalls

1. **Overly strict configuration** - Starting with `strict: true` can be overwhelming. Enable gradually.

2. **Ignoring design checks** - Design category checks (high complexity, too many parameters) flag real problems. Don't disable without review.

3. **Not configuring excluded files** - Dependencies in `deps/` are checked by default. Add them to excluded patterns.

4. **Treating all warnings equally** - Prioritize high-priority issues. Low-priority suggestions are optional.

5. **Disabling checks globally when local disable is better** - Use inline comments for specific exceptions rather than disabling checks entirely.

### Integration Examples

**Elixir 1.13+ format integration:**

Use both formatters in your `mix.exs`:

```elixir
def project do
  [
    formatters: [&Code.format_file!/1],
    # Credo runs as a separate tool
  ]
end
```

**Phoenix projects:**

Credo works seamlessly with Phoenix. Common exclusions:

```elixir
files: %{
  included: ["lib/", "src/", "web/"],
  excluded: ["priv/"]
}
```

**Testing:**

Credo can check test files. Configure separately if using different standards:

```elixir
%{
  name: "test",
  files: %{included: ["test/"]},
  checks: [
    {Credo.Check.Design.DuplicatedCode, false},
    {Credo.Check.Readability.FunctionNames, false}
  ]
}
```

## Command Reference

```bash
mix credo                    # Run all checks on lib/ and src/
mix credo --strict           # Fail on any issue
mix credo --all              # Check all directories including test/
mix credo lib/               # Check specific directory
mix credo explain <file>     # Show detailed explanations
mix credo list               # List all available checks
mix credo suggest            # Show refactoring suggestions only
mix credo diff               # Check only changed files (git-aware)
mix credo --format=json      # Output as JSON for tooling
```

---

**Version:** 1.7.19
**Source:** GitHub (unavailable); content from Credo 1.7.19 model knowledge
**Generated:** 2026-06-17
