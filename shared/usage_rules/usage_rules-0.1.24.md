# usage_rules

UsageRules is a development tool for Elixir projects designed to streamline AI agent integration. It gathers usage rules from dependencies, provides pre-built Elixir guidelines, and enables hexdocs documentation searching through mix tasks.

## Quick Start

### Installation

Add to `mix.exs`:

```elixir
{:usage_rules, "~> 0.1", only: [:dev]}
```

Run `mix deps.get` to fetch the dependency.

### Initial Setup

Sync rules from all dependencies:

```bash
mix usage_rules.sync AGENTS.md --all \
  --inline usage_rules:all \
  --link-to-folder deps
```

This command gathers rules from all dependencies and consolidates them into a specified file.

## Core Concepts

**Usage Rules Files**: Packages provide `usage-rules.md` files containing guidelines for LLM integration. These include general rules plus specialized sub-files for different domains.

**Rules Consolidation**: The tool discovers and collects usage rules from dependencies that provide `usage-rules.md` files in their package directory, organizing them with special markers for independent updating.

**Documentation Search**: The `mix usage_rules.search_docs` task enables querying hexdocs with AI-friendly markdown output, supporting version-specific and package-specific searches.

## Configuration

### Sync Options

- `--all` - Include all dependencies
- `--inline usage_rules:all` - Inline all rules into target file
- `--link-to-folder deps` - Create folder links to dependency files
- `--markdown` - Output rules as separate markdown files
- `--at-style` - Use @-style markers for rule blocks

### Search Configuration

The `search_docs` task supports:

- Version-specific queries: `mix usage_rules.search_docs phoenix 1.7`
- Package-specific searches: `mix usage_rules.search_docs ecto`
- Custom output formatting for AI agent consumption

## Best Practices

**Write Condensed Rules**: Create focused, AI-friendly usage rules tailored to your package. Use aggressive editing to keep rules concise and actionable.

**Use AI Assistance**: Draft initial rules with AI tools, then refine through human review and testing against actual use cases.

**Package Distribution**: Include `usage-rules.md` in your hex package's files configuration for proper distribution:

```elixir
def package do
  [
    files: ["lib", "mix.exs", "README.md", "usage-rules.md"],
    # ...
  ]
end
```

**Organize by Domain**: Structure rules with sub-files for different domains (e.g., `usage-rules-components.md`, `usage-rules-testing.md`) for easier discovery and focused agent guidance.

**Keep Rules Current**: Update rules when breaking changes occur or when you identify new patterns that need documentation.

**AI-Focused Language**: Write rules as direct instructions to AI agents, not users. Use imperative mood and clear, specific guidance.

## Common Tasks

### Update Dependency Rules

```bash
mix usage_rules.sync AGENTS.md --package phoenix
```

### Search Documentation

```bash
mix usage_rules.search_docs ecto connections
```

### List Available Rules

```bash
mix usage_rules.list
```

### Manage Specific Packages

Sync only selected dependencies:

```bash
mix usage_rules.sync AGENTS.md \
  --include phoenix ecto jason \
  --exclude phoenix_live_view
```

---

**Version:** 0.1.24
**Source:** [hexdocs.pm/usage_rules](https://hexdocs.pm/usage_rules/)
**Generated:** 2025-10-28
