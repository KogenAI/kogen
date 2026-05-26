# excoveralls

ExCoveralls is an Elixir library for reporting test coverage statistics using Erlang's cover tool. It can post coverage results to coveralls.io or generate local reports in multiple formats (HTML, JSON, XML, detailed text).

## Quick Start

### Installation

Add to `mix.exs`:

```elixir
def project do
  [
    # ... other config
    test_coverage: [tool: ExCoveralls],
    preferred_cli_env: [
      coveralls: :test,
      "coveralls.detail": :test,
      "coveralls.html": :test,
      "coveralls.json": :test,
      "coveralls.cobertura": :test
    ]
  ]
end

def deps do
  [
    {:excoveralls, "~> 0.18", only: :test}
  ]
end
```

For umbrella projects, each app must have `test_coverage: [tool: ExCoveralls]` independently.

### Basic Usage

```bash
# Run tests with coverage reporting
mix coveralls

# Generate HTML report (saved to cover/excoveralls.html)
mix coveralls.html

# View detailed source code with coverage highlighting
mix coveralls.detail

# Generate JSON report (for Codecov/Code Climate)
mix coveralls.json

# Generate Cobertura XML (for GitLab integration)
mix coveralls.cobertura
```

## Core Concepts

### Mix Tasks

| Task                  | Output                  | Use Case                          |
| --------------------- | ----------------------- | --------------------------------- |
| `coveralls`           | Terminal summary        | Quick local check                 |
| `coveralls.detail`    | Annotated source code   | Identify uncovered lines          |
| `coveralls.html`      | Interactive HTML report | Share with team/dashboard         |
| `coveralls.json`      | JSON format             | Codecov, Code Climate integration |
| `coveralls.cobertura` | XML format              | GitLab, Jenkins integration       |

### Remote Posting

Service-specific tasks upload to coveralls.io:

- `mix coveralls.travis` — Travis CI
- `mix coveralls.github` — GitHub Actions
- `mix coveralls.circle` — CircleCI
- `mix coveralls.post` — Manual upload with repository token

These require repository token configured in environment or `coveralls.json`.

### Coverage Filtering

Use inline comments to control coverage calculation:

```elixir
# coveralls-ignore-start
defmodule Debug do
  # Code in this block is excluded from coverage stats
end
# coveralls-ignore-stop

def production_func do
  # ... code
end
# coveralls-ignore-next-line
defp debug_helper, do: :debug
```

### Merging Coverage Data

For partitioned or integration test suites:

```bash
mix coveralls --import-cover cover_data1.coverdata --import-cover cover_data2.coverdata
```

Merges multiple `.coverdata` files before generating final reports.

## Configuration

Create `coveralls.json` in project root to customize behavior:

```json
{
  "skip_files": ["lib/myapp/test_helper.ex", "lib/myapp/debug/**/*.ex"],
  "minimum_coverage": 80,
  "output_dir": "coverage_reports",
  "treat_no_relevant_lines_as_covered": false
}
```

### Configuration Options

- **`skip_files`** — Array of file patterns to exclude from coverage calculations (glob patterns supported)
- **`minimum_coverage`** — Integer 0-100. Task exits with code 1 if coverage falls below threshold
- **`output_dir`** — Directory path for generated reports (default: `cover/`)
- **`treat_no_relevant_lines_as_covered`** — Boolean. When true, files with no testable lines show 100% coverage; when false, show 0%
- **`coverage_options`** — Pass additional options to Erlang cover tool

## Best Practices

### CI/CD Integration

GitHub Actions example:

```yaml
- name: Run tests with coverage
  run: mix coveralls.github
  env:
    MIX_ENV: test
    GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

### Threshold Enforcement

Set `minimum_coverage` in `coveralls.json` to fail builds on coverage drops:

```json
{
  "minimum_coverage": 85
}
```

Run `mix coveralls` in CI to enforce before merge.

### Umbrella Project Strategy

- Run coverage for each app independently: `cd apps/myapp && mix coveralls`
- Or merge reports: Generate individual `.coverdata` files and import with `--import-cover`
- Track coverage per-app to identify declining coverage in specific services

### Organizing Reports

- **HTML reports** → Commit to `coverage_reports/` and link from README
- **JSON reports** → Send to Codecov dashboard for trend tracking
- **skip_files** → Exclude test helpers, mocks, generated code, debug modules

### Coverage-Driven Testing

1. Run `mix coveralls.detail` to identify uncovered lines
2. Add tests for edge cases or error handling paths
3. Use `coveralls-ignore-*` comments sparingly (prefer improving tests)
4. Set realistic `minimum_coverage` threshold (80-90% typical for production code)

---

**Version:** 0.18.5
**Source:** [hexdocs.pm/excoveralls](https://hexdocs.pm/excoveralls/)
**Generated:** 2025-10-28
