# mix_audit

Mix_audit is a security vulnerability scanner for Elixir projects that scans Mix dependencies for known vulnerabilities. It provides functionality similar to `npm audit` and `bundler-audit`, enabling developers to identify and manage security risks in their Elixir projects.

## Quick Start

### Installation as Project Dependency

Add to your `mix.exs` file:

```elixir
defp deps do
  [
    {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false}
  ]
end
```

Then run:

```bash
mix do deps.get, deps.compile
mix deps.audit
```

### Installation as Global Executable

Install as an escript if you prefer not to include it in project dependencies:

```bash
mix escript.install hex mix_audit
```

### System Requirements

- Git
- Elixir version 1.8 or higher

## Core Concepts

### How It Works

Mix_audit performs three main steps to scan for vulnerabilities:

1. **Fetches Security Advisories**: Downloads known vulnerability database from the `elixir-security-advisories` GitHub repository
2. **Extracts Dependencies**: Reads dependency information from project `mix.lock` files
3. **Matches Against Advisories**: Compares dependencies (name and version) against known vulnerabilities

### Exit Status

- **Status 0**: No vulnerabilities found
- **Status 1**: Vulnerabilities detected

This behavior makes mix_audit suitable for CI/CD pipelines that need to fail builds on security issues.

### Comparison with `mix hex.audit`

Mix_audit scans for **reported security vulnerabilities** in dependencies, whereas Hex's built-in `mix hex.audit` identifies **retired packages**. Both tools serve complementary security purposes:

- Use `mix hex.audit` to detect retired/unmaintained packages
- Use `mix deps.audit` to find known security vulnerabilities

## Configuration

### Command-Line Options

| Option                   | Type   | Default           | Purpose                               |
| ------------------------ | ------ | ----------------- | ------------------------------------- |
| `--path`                 | String | Current directory | Project root to audit                 |
| `--format`               | String | "human"           | Output format: "json" or "human"      |
| `--ignore-advisory-ids`  | String | ""                | Comma-separated advisory IDs to skip  |
| `--ignore-package-names` | String | ""                | Comma-separated package names to skip |
| `--ignore-file`          | String | ""                | Path to ignore configuration file     |

### Usage Examples

**Basic scan (human-readable output)**:

```bash
mix deps.audit
```

**JSON output for programmatic parsing**:

```bash
mix deps.audit --format json
```

**Audit specific project directory**:

```bash
mix deps.audit --path /path/to/project
```

**Ignore specific advisories**:

```bash
mix deps.audit --ignore-advisory-ids ADVISORY-1,ADVISORY-2
```

**Ignore specific packages**:

```bash
mix deps.audit --ignore-package-names httpoison,phoenix
```

**Load ignore list from file**:

```bash
mix deps.audit --ignore-file .audit-ignore
```

## Best Practices

### CI/CD Integration

Include mix_audit in your CI/CD pipeline to fail builds on security issues:

```bash
# In CI configuration (GitHub Actions, GitLab CI, etc.)
mix deps.audit
```

### Handling Vulnerabilities

When `mix deps.audit` reports vulnerabilities:

1. **Update Dependencies**: Run `mix deps.update` to patch vulnerable packages
2. **Verify Compatibility**: Test updated dependencies thoroughly
3. **Document Decisions**: Use `--ignore-advisory-ids` only for accepted risks with documentation
4. **Track Status**: Re-run `mix deps.audit` to verify fixes

### Ignore File Management

Create `.audit-ignore` file for persistent exception management:

```
# Format: one advisory ID or package name per line
ADVISORY-123
ADVISORY-456
old-legacy-package
```

### Development vs Production

- **Development**: Include mix_audit as a dev/test dependency
- **Global**: Use escript installation for tools shared across projects
- **Never use runtime: true** - security auditing is a build-time tool

### Regular Auditing

- Run `mix deps.audit` before each release
- Monitor CI/CD pipeline for audit failures
- Update dependencies regularly to stay ahead of vulnerabilities
- Subscribe to security advisory updates for critical packages

---

**Version:** 2.1.5
**Source:** [hexdocs.pm/mix_audit](https://hexdocs.pm/mix_audit/)
**License:** New BSD
**Generated:** 2025-10-28
