# sobelow

**Sobelow** is a static analysis tool designed to identify security vulnerabilities in Elixir and Phoenix applications. It serves developers and security researchers conducting code reviews, helping prevent common security issues through automated vulnerability detection.

## Quick Start

### Installation

Add to your `mix.exs` dependencies:

```elixir
{:sobelow, "~> 0.14", only: [:dev, :test], runtime: false}
```

Or install globally as an escript:

```bash
mix escript.install hex sobelow
```

### Running Scans

From your project root, run:

```bash
# Basic scan
mix sobelow

# Verbose output with code snippets
mix sobelow --verbose

# JSON format for CI/CD integration
mix sobelow --format json

# Skip known false positives
mix sobelow --ignore Traversal,XSS
```

## Core Concepts

### Vulnerability Categories

Sobelow detects multiple security issue types:

- **XSS (Cross-Site Scripting)** - Unescaped user input in templates
- **SQL Injection** - Unsanitized SQL queries
- **Command Injection** - Shell command vulnerabilities
- **Code Execution** - Unsafe code evaluation patterns
- **Insecure Dependencies** - Known vulnerable library versions
- **Denial of Service** - Resource exhaustion vulnerabilities
- **Directory Traversal** - Path manipulation attacks
- **Unsafe Serialization** - Object deserialization risks
- **Insecure Configuration** - Misconfigured security settings

### Confidence Levels

Findings are color-coded by confidence:

- **Red** - High confidence: likely a real vulnerability
- **Yellow** - Medium confidence: potential issue requiring verification
- **Green** - Low confidence: possible but uncertain

## Configuration

### Command-Line Flags

| Flag              | Description                                       |
| ----------------- | ------------------------------------------------- |
| `--verbose, -v`   | Show code snippets with findings                  |
| `--ignore, -i`    | Exclude finding types (comma-separated)           |
| `--format, -f`    | Output format: `txt` (default) or `json`          |
| `--threshold`     | Minimum confidence level: `high`, `medium`, `low` |
| `--exit`          | Exit status: `low`, `medium`, `high`              |
| `--mark-skip-all` | Tag all findings with `# sobelow_skip` comments   |

### Configuration File

Create `.sobelow-conf` in your project root to store persistent configuration:

```
# sobelow configuration file
ignore = Traversal,Serialization
threshold = medium
format = txt
```

For umbrella applications, create separate `.sobelow-conf` files in each child app's root directory.

### Marking False Positives

Add comments above functions to skip specific findings:

```elixir
# sobelow_skip: ["XSS.Raw"]
def render_html(content) do
  # This is safe because content is pre-validated
  {:safe, content}
end
```

Or mark all current findings with `--mark-skip-all`:

```bash
mix sobelow --mark-skip-all
```

## Best Practices

### Integration Workflow

1. **Initial Setup**: Run `mix sobelow` to establish baseline findings
2. **Review False Positives**: Use `--mark-skip-all` to tag known non-issues
3. **Incremental Fixes**: Address real vulnerabilities in priority order
4. **CI/CD Integration**: Use `--format json` and `--exit high` for automated checks
5. **Threshold Management**: Use `--threshold medium` to focus on likely issues

### CI/CD Integration

For GitHub Actions or similar CI systems:

```bash
mix sobelow --format json --exit high --threshold medium
```

This ensures only high-confidence findings block the pipeline.

### Development Workflow

Run before commits for immediate feedback:

```bash
# Quick scan with verbose output
mix sobelow --verbose

# Skip already-marked findings
mix sobelow --ignore marked-findings
```

### Umbrella Applications

Each child app should have its own configuration:

```
umbrella_app/
├── .sobelow-conf                    # Parent config (optional)
├── apps/web/
│   ├── .sobelow-conf              # Web app specific
│   └── lib/
└── apps/api/
    ├── .sobelow-conf              # API app specific
    └── lib/
```

Run scans in each app directory independently.

### Performance Optimization

- Use `--ignore` to skip irrelevant checks for your codebase
- Run on relevant directories only (not dependencies)
- For large projects, use `--threshold high` initially to reduce noise

---

**Version:** 0.14.1
**Source:** [hexdocs.pm/sobelow](https://hexdocs.pm/sobelow/)
**Generated:** 2025-10-28
