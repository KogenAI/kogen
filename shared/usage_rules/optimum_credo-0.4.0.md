# optimum_credo

Custom Credo checks enforcing code quality and consistency patterns to reduce manual review cycles across Elixir projects. Covers readability, type safety, and testing best practices.

## Quick Start

Add to `mix.exs`:

```elixir
{:optimum_credo, "~> 0.4", only: [:dev, :test], runtime: false}
```

Enable in `.credo.exs`:

```elixir
configs: [
  %{
    name: "default",
    files: %{included: ["lib/", "test/"], excluded: []},
    checks: [
      {OptimumCredo.Checks.ModuleOrganization, []},
      {OptimumCredo.Checks.SkippedTest, []},
      # ... other checks
    ]
  }
]
```

Run `mix credo` to validate code against all enabled checks.

## Core Concepts

OptimumCredo groups checks into three domains:

**Readability Checks** — Enforce structural consistency:

- `ModuleOrganization` — Requires blank lines between function groups (imports, typespecs, function definitions)
- `DocumentationFormatting` — Ensures proper spacing in doc comments (`@doc` and `@moduledoc`)
- `UnusedTypes` — Detects unused `@type` definitions cluttering modules
- `ExtractableSpecTypes` — Promotes repeated types to aliases for reusability
- `DepsOrder`, `ImportOrder`, `TypespecOrder` — Alphabetical ordering within each section
- `PrivateFunctionSpecs` — Flags unnecessary specs on private functions (already inferred)

**Type & Documentation Checks** — Strengthen semantic clarity:

- `VerboseAssertions` — Flags overly complex assertion patterns; prefer simpler idioms
- Emphasis on extracting types and reducing repeated type patterns

**Testing & Stability Checks** — Catch hidden issues:

- `SkippedTest` — Detects `skip` or conditional test runs hiding failures
- `RuntimeEnvDevDefault` — Catches developer-only config paths escaping to production
- `EmptySetupBlock` — Identifies noise-generating empty `setup` blocks in tests
- `LiveViewBareMatch` — Prevents unguarded pattern matches in LiveView events that crash processes
- `CaseTrueFalse` — Suggests `if` expressions instead of redundant `case true/false` statements

## Configuration

Each check accepts a `[]` configuration tuple in `.credo.exs`. Most checks require no options.

For selective enablement, include only desired checks in the checks list:

```elixir
checks: [
  {OptimumCredo.Checks.ModuleOrganization, []},
  {OptimumCredo.Checks.SkippedTest, []},
  {OptimumCredo.Checks.LiveViewBareMatch, []},
]
```

Omit checks to disable them. Checks not listed do not run.

## Best Practices

1. **Enforce readability first** — Start with `ModuleOrganization` and ordering checks; these catch low-friction structure issues that accumulate
2. **Catch hidden tests early** — Enable `SkippedTest` to prevent accidentally committing skipped tests
3. **Type extraction** — Use `ExtractableSpecTypes` and `UnusedTypes` to keep type definitions DRY and discoverable
4. **Production safety** — Always enable `RuntimeEnvDevDefault` to prevent dev-only config leaking
5. **LiveView stability** — If using Phoenix LiveView, enable `LiveViewBareMatch` to prevent silent crashes from unmatched patterns
6. **Iterative adoption** — Introduce checks gradually; retrofitting existing codebases may flag many violations. Enable one check, fix violations, commit, then enable the next

Run `mix credo` as part of CI/CD gates to enforce consistency before merge.

---

**Version:** 0.4.0  
**Source:** [hexdocs.pm/optimum_credo](https://hexdocs.pm/optimum_credo/0.4.0/)  
**Repository:** [github.com/optimumBA/optimum_credo](https://github.com/optimumBA/optimum_credo)  
**Generated:** 2026-05-09
