# ex_doc

ExDoc generates beautiful HTML, Markdown, and EPUB documentation for Elixir and Erlang projects with built-in full-text search, responsive design, and auto-linking between modules and functions.

## Quick Start

### Installation

Add to `mix.exs` dependencies:

```elixir
def deps do
  [
    {:ex_doc, "~> 0.40", only: :dev, runtime: false, warn_if_outdated: true},
  ]
end
```

Run:

```bash
mix deps.get
mix docs
```

The generated documentation appears in the `doc/` directory.

### Command Line (escript)

For standalone usage without a Mix project:

```bash
mix escript.install hex ex_doc
ex_doc "ProjectName" "1.0.0" _build/dev/lib/project/ebin \
  -m "ModuleName" -u "https://github.com/user/repo"
```

### Rebar3 (Erlang)

On OTP 24+, use `rebar3_ex_doc` plugin to render EDoc-formatted documentation.

## Core Concepts

### Documentation Generation

ExDoc processes Elixir modules, functions, types, and documentation comments to produce:

- **HTML** — interactive web documentation with search and keyboard navigation
- **EPUB** — ebooks for offline reading
- **Markdown** — static files for integration into wikis or static sites

### Auto-Linking Syntax

Link modules and functions directly in documentation comments:

- Module: `` `MyModule` ``
- Function/macro: `` `MyModule.function/1` ``
- Callback: `` `c:MyModule.callback/2` ``
- Type: `` `t:MyModule.type/0` ``
- Custom text: ``[click here](`MyModule.function/1`)``

### Supported Extras

Include additional documentation files alongside module docs:

- **Markdown** (`.md`) — full Markdown format with auto-linking
- **Cheatsheets** (`.cheatmd`) — single-page reference cards
- **Livebooks** (`.livemd`) — interactive notebook documentation

## Configuration

Set documentation options in `mix.exs`:

```elixir
def project do
  [
    name: "My Project",
    source_url: "https://github.com/user/repo",
    homepage_url: "https://example.com",
    docs: [
      main: "readme",
      logo: "path/to/logo.png",
      favicon: "path/to/favicon.ico",
      extras: ["README.md", "CHANGELOG.md", "guides/overview.md"],
      groups_for_modules: [
        "Core": [MyModule, MyModule.Core],
        "Utils": [MyModule.Utils]
      ],
      skip_undefined_reference_warnings: ["MyModule.Deprecated"]
    ]
  ]
end
```

### mix docs Task Options

Override config via command line:

- `--canonical URL` — set preferred URL with canonical link
- `--formatter html|epub|markdown` — output formats (repeatable)
- `--language BCP47` — EPUB language code
- `--open` — open docs in browser after generation
- `--output DIR` — destination directory (default: `doc`)
- `--proglang elixir|erlang` — primary language for syntax highlighting
- `--warnings-as-errors` — fail build on documentation warnings

### Umbrella Projects

For umbrella projects, ExDoc generates unified documentation across all child apps. Use `:ignore_apps` to exclude specific projects:

```elixir
docs: [
  ignore_apps: [:internal_app, :test_only]
]
```

Generate individual app documentation with: `mix cmd mix docs`

## Best Practices

### Documentation Comments

Use clear, complete docstrings for all public APIs:

```elixir
@doc """
Performs a calculation.

Takes two numbers and returns their sum. Use this when you need
simple arithmetic operations.

## Examples

    iex> add(2, 3)
    5

    iex> add(-1, 1)
    0
"""
def add(a, b) do
  a + b
end
```

### Organize with Groups

Use `groups_for_modules` and `groups_for_functions` to organize documentation:

```elixir
docs: [
  groups_for_modules: [
    "Public API": [App.API, App.API.Client],
    "Internal": [App.Internal, App.Internal.Utils]
  ],
  groups_for_functions: [
    "Query": ~r/^query_/,
    "Mutations": ~r/^mutate_/
  ]
]
```

### Version and Canonical URLs

Always set `:version` and `:source_url` to help users navigate source code:

```elixir
project: [
  version: "1.0.0",
  source_url: "https://github.com/org/project/blob/v#{Mix.Project.config()[:version]}"
]
```

Use `--canonical` flag for deployment to ensure search engines index the official version.

### Extra Files

Include essential docs as extras for prominence:

```elixir
docs: [
  main: "readme",
  extras: [
    "README.md",
    "CHANGELOG.md",
    "guides/installation.md",
    "guides/usage.md"
  ]
]
```

### Module Visibility

Control which modules appear in documentation:

```elixir
@moduledoc false  # Hide module entirely

@doc false        # Hide individual function
def internal_helper, do: :ok
```

Use for internal utilities and deprecated APIs.

### Suppress Warnings

Skip specific undefined reference warnings:

```elixir
docs: [
  skip_undefined_reference_warnings: [
    "Module.deprecated_function/1",
    "OtherLib.function/0"
  ]
]
```

---

**Version:** 0.40.1
**Source:** [hexdocs.pm/ex_doc](https://hexdocs.pm/ex_doc/)
**Generated:** 2026-04-25
