# usage_rules

UsageRules is an Elixir development tool that aggregates usage guidelines from project dependencies and provides AI-friendly documentation search capabilities to prevent LLM hallucinations.

## Quick Start

**Installation via Igniter:**

```bash
mix igniter.install usage_rules
```

**Installation via Mix:**
Add to `mix.exs`:

```elixir
{:usage_rules, "~> 0.1.25"}
```

**Basic Usage:**

```bash
# Sync all dependency usage rules into a single file
mix usage_rules.sync AGENTS.md --all

# Sync specific dependency rules
mix usage_rules.sync path/to/output.md --deps ash phoenix ecto

# Search documentation across packages
mix usage_rules.search_docs "query terms"
```

## Core Concepts

**Dependency Rule Aggregation**

- Automatically discovers `usage-rules.md` files in project dependencies
- Consolidates multiple rule files into a single target file
- Maintains independent update markers for each dependency
- Particularly beneficial for frameworks like Ash, Phoenix, and other packages

**Pre-built Elixir Rules**

- Provides ready-made guidelines for Elixir development patterns
- Framework-specific rules for Phoenix, Ash, and other popular packages
- Prevents AI tools from hallucinating incorrect usage patterns

**Documentation Search**

- Query hexdocs with AI-friendly markdown output
- Searches across all installed packages
- Formats results for easy consumption by language models

## Configuration

**Target File Organization:**

```bash
# Sync to project root for agent access
mix usage_rules.sync AGENTS.md --all

# Organize into subfolder
mix usage_rules.sync docs/usage_rules.md --all

# Sync specific dependencies only
mix usage_rules.sync usage_rules/custom.md --deps ash phoenix ecto
```

**Dependency Selection:**

- `--all` flag: Includes all dependencies with usage rules
- Explicit list: Specify individual packages to sync
- Automatic discovery: Searches for `usage-rules.md` in each dependency

**Output Format:**

- Single consolidated markdown file
- Clear section headers for each dependency
- Maintains rule hierarchy and formatting
- Includes version information for each rule set

## Best Practices

**For AI Agent Integration:**

- Sync rules before starting agent-assisted development sessions
- Place `AGENTS.md` or equivalent in project root for agent discovery
- Update rules regularly as dependencies update: `mix usage_rules.sync AGENTS.md --all`
- Reference synced rules in agent prompts to ground AI responses

**For Package Maintainers:**

- Create `usage-rules.md` files to guide framework usage
- Reference the Ash Framework's comprehensive usage rules as a template
- Include examples of correct and incorrect patterns
- Update rules when API changes occur

**For Development Workflows:**

- Sync rules at project initialization
- Re-sync before major feature development
- Include rule syncing in CI/CD pipelines if rules drive generation
- Version-lock usage_rules version for consistency across team

**Documentation Search:**

- Use `mix usage_rules.search_docs` for specific feature lookups
- Incorporates search results into AGENTS.md for agent context
- Refine searches with specific terminology for better results
- Useful for exploring unfamiliar packages and their patterns

## Advanced Usage

**Integration with Igniter:**

- usage_rules works alongside Igniter for code generation
- Rule files inform generated code patterns
- Automatic sync during project initialization

**Custom Rule Organization:**

- Link to specific folders for organized rule management
- Create role-specific rule subsets for different team members
- Maintain separate rule files for different projects

**Backward Compatibility:**

- Tool maintains compatibility across versions
- Existing projects continue to work with new releases
- Gradual deprecation of outdated patterns

---

**Version:** 0.1.25
**Source:** [hexdocs.pm/usage_rules](https://hexdocs.pm/usage_rules/)
**Generated:** 2025-10-28
