# dialyxir

Static analysis tool for Elixir that uses Dialyzer (a BEAM static analysis framework) to identify type mismatches, unmatched function returns, type guard failures, and other potential code issues. Dialyxir manages the PLT (Persistent Lookup Table) caching layer and CLI interface.

## Quick Start

### Installation

Add to `mix.exs` dependencies:

```elixir
defp deps do
  [
    {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
  ]
end
```

Run `mix do deps.get, deps.compile`.

### Basic Usage

```bash
mix dialyzer
```

Automatically creates/updates PLT files, compiles project, and reports warnings. Exit code is non-zero if warnings found.

## Core Concepts

### Persistent Lookup Table (PLT)

PLT files cache analysis results for faster subsequent runs. Dialyxir manages three by default:

- **Core Erlang PLT** – Erlang standard library (auto-built on first run)
- **Core Elixir PLT** – Elixir stdlib (auto-built on first run)
- **Project PLT** – Your application code (rebuilt on dependency changes)

Customize locations via config:

```elixir
dialyzer: [
  plt_local_path: "priv/plts/project.plt",
  plt_core_path: "priv/plts/core.plt",
]
```

### Warning Categories

Common warnings:

- **Unmatched Returns** – Function returns type not matched in call site
- **Guard Failures** – Guard test can never succeed (e.g., `is_binary(non_binary_var)`)
- **No Local Return** – Function can never return normally (infinite loop, always raises)
- **Overlapping Clauses** – Pattern match clause unreachable

## Configuration

Add to `mix.exs` project block:

```elixir
dialyzer: [
  plt_local_path: "priv/plts/project.plt",
  plt_core_path: "priv/plts/core.plt",
  plt_add_deps: :apps_direct,        # Include direct dependencies
  plt_add_apps: [:wx],                # Add OTP apps to PLT
  plt_ignore_apps: [:mnesia],         # Exclude apps from PLT
  flags: ["-Wunmatched_returns"],     # Enable specific warnings
  paths: ["_build/dev/lib/my_app/ebin"], # Custom BEAM paths
  ignore_warnings: ".dialyzer_ignore.exs",
  list_unused_filters: true,          # Warn about obsolete ignores
]
```

## Best Practices

### Type Specs

Include `@spec` annotations for better analysis:

```elixir
@spec my_function(String.t(), integer()) :: {:ok, term()} | {:error, String.t()}
def my_function(str, count) do
  # Implementation
end
```

Dialyzer uses specs to infer types in callers; incomplete specs reduce effectiveness.

### Ignoring Warnings

**Module attribute** (single function):

```elixir
defmodule MyApp.Repo do
  @dialyzer {:nowarn_function, rollback: 1}
end
```

**Ignore file** (string format, `.dialyzer-ignore`):

```
Guard test is_binary can never succeed
Function init/1 has no local return
```

**Ignore file** (Elixir term format, `.dialyzer_ignore.exs`):

```elixir
[
  {"lib/file.ex", :no_return},
  {"lib/file.ex", "Function init/1 has no local return."},
  ~r/my_file\.ex.*no local return/
]
```

Generate templates: `mix dialyzer --format ignore_file_strict`

### CI Integration

Cache PLT files between runs for speed:

```bash
# Add to .gitignore
*.plt
*.plt.hash
```

Store project PLTs in `priv/plts/`. Rebuild PLTs when changing Erlang or Elixir versions—cached PLTs from mismatched OTP versions cause false positives.

### Common Flags

```bash
mix dialyzer --no-compile          # Skip compilation step
mix dialyzer --no-check            # Bypass PLT update verification
mix dialyzer --ignore-exit-status  # Display warnings, exit 0
mix dialyzer --list-unused-filters # Show obsolete ignore entries
mix dialyzer --format github       # GitHub Actions output
mix dialyzer --quiet               # Suppress info messages
```

### Debugging

- `mix dialyzer.explain <warning>` – Get guidance on a warning type
- Enable `flags: ["-Wunknown"]` – Catch incomplete PLTs early
- Add specs incrementally – Better specs improve analysis accuracy
- Re-run with `--no-check` if PLT seems stale

---

**Version:** 1.4.7
**Source:** [hexdocs.pm/dialyxir](https://hexdocs.pm/dialyxir/)
**Generated:** 2026-04-25
