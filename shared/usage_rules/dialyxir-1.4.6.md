# dialyxir

Dialyxir is a Mix task wrapper that simplifies using Dialyzer (Erlang's static analysis tool) in Elixir projects. It provides Mix tasks for static type analysis, detecting type mismatches, unmatched returns, and other potential issues before runtime. Dialyxir manages the PLT (Persistent Lookup Table) automatically and formats analysis results in multiple output formats.

## Quick Start

### Installation

Add to your `mix.exs` dependencies (dev/test only, not runtime):

```elixir
defp deps do
  [
    {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
  ]
end
```

Install dependencies:

```bash
mix do deps.get, deps.compile
```

### Basic Analysis

Run analysis from your project directory:

```bash
mix dialyzer
```

Dialyxir automatically creates or updates the PLT file and compiles your project as needed.

## Core Concepts

**PLT (Persistent Lookup Table)**

- A cache file that stores type information about your code and dependencies
- Created automatically on first run (takes time on initial execution)
- Reused in subsequent runs for faster analysis
- Located at `.dialyzer_plt` by default

**Type Analysis**

- Detects type mismatches between function definitions and call sites
- Identifies unmatched return values
- Finds error handling issues
- Reports dead code patterns

**Mix Task Integration**

- Runs within the standard Mix task ecosystem
- Respects Mix environments and configurations
- Compatible with standard Elixir project structure

## Configuration

### Basic Configuration

Add to `mix.exs` project configuration:

```elixir
def project do
  [
    # ...other config...
    dialyzer: [
      plt_add_apps: [:wx],
      plt_ignore_apps: [:mnesia],
      flags: [:unmatched_returns, :error_handling]
    ]
  ]
end
```

### Common Configuration Options

- **`plt_add_apps`** - Additional OTP applications to include in PLT
- **`plt_ignore_apps`** - Applications to exclude from PLT
- **`flags`** - Analysis flags controlling which issues to detect
- **`list_unused_filters`** - Show unused filter directives

## Common Commands

**Run with standard analysis:**

```bash
mix dialyzer
```

**Skip recompiling (faster):**

```bash
mix dialyzer --no-compile
```

**Get help for specific warnings:**

```bash
mix dialyzer.explain unmatched_return
```

**Output format options:**

- `mix dialyzer --format short` — Compact output
- `mix dialyzer --format dialyzer` — Original Dialyzer format
- `mix dialyzer --format github` — GitHub Actions format

**Remove and recreate PLT:**

```bash
mix dialyzer.clean
mix dialyzer
```

## Best Practices

**Run regularly in development**

- Add to CI/CD pipelines to catch issues early
- Use GitHub Actions format for integration with pull requests
- Run on feature branches before merging

**Manage PLT size**

- Use `plt_ignore_apps` to exclude unnecessary dependencies
- Rebuild PLT periodically with `mix dialyzer.clean`
- Monitor `.dialyzer_plt` file size in version control decisions

**Handle warnings effectively**

- Use `mix dialyzer.explain` to understand complex warnings
- Filter false positives with configuration rather than ignoring
- Keep analysis flags focused on relevant issue types

**Incremental analysis**

- Run `mix dialyzer --no-compile` for faster checks during development
- Use full analysis before commits or CI runs
- Balance feedback speed with coverage completeness

---

**Version:** 1.4.6
**Source:** [hexdocs.pm/dialyxir](https://hexdocs.pm/dialyxir/)
**Generated:** 2025-10-28
