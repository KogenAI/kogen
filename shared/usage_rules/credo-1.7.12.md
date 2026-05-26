# credo

Static code analysis tool for Elixir with focus on teaching and code consistency. Helps identify refactoring opportunities, flag complex code, catch common errors, and enforce naming conventions.

## Quick Start

### Installation

Add to `mix.exs` dependencies:

```elixir
defp deps do
  [
    {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
  ]
end
```

Run `mix deps.get` to fetch dependencies.

### Basic Usage

Run analysis on entire project:

```bash
mix credo
```

Get detailed explanation for specific file/line:

```bash
mix credo lib/foo/bar.ex:306
```

## Core Concepts

### Check Categories

Credo detects:

- **Refactoring opportunities** - Code that could be simplified
- **Complex code fragments** - Functions/modules that are too complex
- **Programming mistakes** - Common errors and anti-patterns
- **Naming inconsistencies** - Variables/functions that violate conventions
- **Code style violations** - Enforced consistency patterns

### Issue Priorities

Issues assigned with priority indicators (↑ ↗ → ↘ ↓) based on:

- Check severity and type
- Configuration settings
- Code context

Default output shows only higher-priority issues; use `--strict` for all findings.

### Educational Focus

Core philosophy: teach developers why issues matter, not just flag violations. Detailed explanations available for each issue.

## Configuration

### Default Behavior

Credo works out-of-box with sensible defaults. Configuration optional via `.credo.exs` file in project root.

### Output Formats

**Standard output** (default):

```bash
mix credo
```

**All issues** (including lower priority):

```bash
mix credo --strict
```

**JSON format** (for programmatic use):

```bash
mix credo --format json
```

**Get help** on specific issue:

```bash
mix credo lib/foo/bar.ex:306
```

Returns: check name, explanation, configuration details, and disabling instructions.

## Best Practices

### Integration

- **Development workflow**: Run `mix credo` before commits
- **CI/CD pipelines**: Use `mix credo --strict` for comprehensive checks
- **Pre-commit hooks**: Integrate with git hooks for automatic analysis

### Understanding Results

- Focus on higher-priority issues first (default display)
- Read detailed explanations for each issue using specific file:line syntax
- Understand why violations matter (Credo emphasizes education)

### Compatibility

- Compatible with actively supported Elixir minor releases
- May work with earlier versions; check compatibility notes
- Tested against modern Elixir versions

---

**Version:** 1.7.12
**Source:** [hexdocs.pm/credo](https://hexdocs.pm/credo/)
**Generated:** 2025-10-28
