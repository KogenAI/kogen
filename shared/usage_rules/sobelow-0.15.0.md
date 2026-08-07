# sobelow

Sobelow is a security-focused static analysis tool for Elixir projects that detects vulnerabilities across multiple security domains. It provides automated scanning of code for common security issues, helping teams identify and fix vulnerabilities early in development.

## Quick Start

### Installation

Add Sobelow to your `mix.exs` dependencies:

```elixir
defp deps do
  [
    {:sobelow, "~> 0.15", only: [:dev, :test], runtime: false}
  ]
end
```

Then run `mix deps.get`.

Alternatively, install globally as an escript:

```bash
mix escript.install hex sobelow
```

### Basic Usage

Run security scanning from your project root:

```bash
mix sobelow
```

This analyzes your entire codebase and reports findings organized by severity and confidence level.

## Core Concepts

### Vulnerability Categories

Sobelow detects issues across multiple domains:

- **XSS (Cross-Site Scripting)** - Template injection and unsafe rendering
- **SQL Injection** - Unsafe database queries and parameterization
- **Command Injection** - Unsafe system command execution
- **Insecure Configuration** - Weak security settings in config files
- **Vulnerable Dependencies** - Known vulnerabilities in dependencies
- **Code Execution** - Unsafe code evaluation and dynamic execution
- **Directory Traversal** - Path traversal vulnerabilities
- **Denial of Service** - DoS vectors and resource exhaustion
- **Unsafe Serialization** - Unsafe object deserialization

### Confidence Levels

Findings are color-coded:

- **Red** - High confidence: strong indicator of vulnerability
- **Yellow** - Medium confidence: potential issue requiring verification
- **Green** - Low confidence: possible but low likelihood

## Configuration

### Command-Line Options

Common flags:

- `--verbose` - Display code snippets and additional context for each finding
- `--ignore CHECKS` - Exclude specific check types (comma-separated)
- `--format FORMAT` - Output format: `txt` (default) or `json`
- `--exit CONFIDENCE` - Set exit code based on confidence level
- `--config FILE` - Load configuration from a file
- `--skip-deps` - Skip scanning dependencies

### Configuration File

Create `.sobelow-conf` in your project root to save frequent options:

```
--verbose
--exit high
```

Then run `mix sobelow` to apply saved configuration automatically without repeating flags.

### Ignoring Specific Checks

Ignore particular vulnerability checks by type:

```bash
mix sobelow --ignore XSS,SQLInjection
```

Or configure in `.sobelow-conf`:

```
--ignore XSS,CommandInjection
```

## Best Practices

### Integration into Development Workflow

1. **Add to CI/CD** - Run Sobelow in continuous integration to catch vulnerabilities early
2. **Local Pre-commit** - Run before committing to prevent vulnerable code from entering the repository
3. **Regular Scanning** - Run periodically even in mature projects to catch new patterns

### Handling Findings

- Address **high confidence** findings immediately as they likely indicate real vulnerabilities
- Investigate **medium confidence** findings to determine if they represent actual security risks
- Review **low confidence** findings for context but prioritize higher-confidence issues
- Use `--verbose` to see code context when triaging findings

### Configuration Strategy

- Configure `.sobelow-conf` with your team's preferred options for consistency
- Use `--exit` with appropriate confidence level to fail CI builds on critical findings
- Exclude known safe patterns only after careful review, not as a default practice
- Document any checks you ignore and why, to prevent assumption drift

### Working with Dependencies

Sobelow can scan dependencies for vulnerabilities. Regularly update dependencies and re-run scans to catch published vulnerabilities. For dependency-specific issues, refer to your dependency's security advisories.

---

**Version:** 0.15.0
**Source:** [github.com/nccgroup/sobelow](https://github.com/nccgroup/sobelow)
**Generated:** 2026-08-07
