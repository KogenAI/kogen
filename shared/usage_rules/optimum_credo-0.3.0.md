# optimum_credo

Custom static analysis checks for Elixir projects that enforce code quality, consistency, and readability patterns. OptimumCredo integrates with Credo to reduce manual code review cycles through automated style enforcement.

## Quick Start

### Installation

Add to your `mix.exs` dependencies (dev/test only):

```elixir
def deps do
  [
    {:optimum_credo, "~> 0.3", only: [:dev, :test], runtime: false},
  ]
end
```

Run `mix deps.get` to fetch the package.

### Basic Setup

1. Add checks to `.credo.exs` configuration in your checks list
2. Run `mix credo` to execute all checks including optimum_credo rules
3. Address reported violations in your codebase

## Core Concepts

OptimumCredo provides **nine custom checks** organized into two categories:

### Readability Checks (6 checks)

**ModuleOrganization** — Requires blank lines between `use`, `import`, `alias`, and `require` statements. Improves code readability by visually grouping related declarations.

**DocumentationFormatting** — Validates proper spacing after documentation section headers (e.g., `## Examples:` or `## Returns`). Ensures consistent doc formatting across modules.

**VerboseAssertions** — Simplifies test assertions by removing redundant comparisons. Converts `assert item.id != nil` to `assert item.id` for cleaner test code.

**UnusedTypes** — Identifies unused `@type` definitions that can be safely removed. Reduces module clutter and improves maintainability.

**ExtractableSpecTypes** — Encourages extracting repeated types in function specs to reusable module-level type aliases. Reduces duplication in type specifications.

**PrivateFunctionSpecs** — Flags `@spec` declarations on private functions. Private function specs are unnecessary and should be removed (Elixir doesn't require them).

### Ordering Checks (3 checks)

Three original checks enforce alphabetical ordering:

- **Dependencies/imports** — Keeps dependency lists sorted alphabetically
- **Aliases** — Maintains alphabetical order of `alias` statements
- **Typespecs** — Orders function specifications consistently

## Configuration

### Adding Checks to `.credo.exs`

Checks are configured in your project's `.credo.exs` file:

```elixir
%{
  configs: [
    %{
      name: "default",
      checks: [
        {Optimum.Credo.Check.Readability.ModuleOrganization, []},
        {Optimum.Credo.Check.Readability.DocumentationFormatting, []},
        {Optimum.Credo.Check.Readability.VerboseAssertions, []},
        {Optimum.Credo.Check.Readability.UnusedTypes, []},
        {Optimum.Credo.Check.Readability.ExtractableSpecTypes, []},
        {Optimum.Credo.Check.Readability.PrivateFunctionSpecs, []},
      ]
    }
  ]
}
```

### Disabling Individual Checks

Add to your `.credo.exs` with `false` to disable specific checks:

```elixir
{Optimum.Credo.Check.Readability.ModuleOrganization, false}
```

## Best Practices

### Code Organization

- Maintain the suggested module organization pattern: `use`, then `import`, then `alias`, then `require`, separated by blank lines
- Group related imports and aliases together logically before organizing alphabetically
- Extract module-level type definitions for frequently repeated specs to improve maintainability

### Documentation Standards

- Use consistent spacing after documentation headers (add `:` if needed)
- Keep documentation concise and well-formatted for better readability
- Ensure section headers follow the pattern `## SectionName:` or `## SectionName`

### Testing

- Use simplified assertion patterns in tests (avoid unnecessary `!= nil` checks)
- Write assertions that are self-documenting and easier to read
- Keep test assertions focused on the behavior being tested

### Type Safety

- Remove unused `@type` definitions regularly to keep modules clean
- Define module-level type aliases for specs used more than once
- Avoid unnecessary specs on private functions (they're not part of the public API)

### Workflow Integration

- Run `mix credo` as part of your development workflow
- Address all optimum_credo violations before code review
- Integrate checks into CI/CD pipelines to enforce consistency automatically
- Use violations to guide team code style standards

---

**Version:** 0.3.0  
**Source:** [hexdocs.pm/optimum_credo](https://hexdocs.pm/optimum_credo/)  
**License:** MIT  
**Repository:** [github.com/optimumBA/optimum_credo](https://github.com/optimumBA/optimum_credo)  
**Generated:** 2026-04-25
