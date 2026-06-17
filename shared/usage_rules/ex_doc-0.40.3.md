# ex_doc

ExDoc is a tool for generating documentation for Erlang and Elixir projects. It creates offline-accessible HTML, Markdown, and EPUB documents from API documentation and guides with responsive design, full-text search, and keyboard shortcuts.

## Quick Start

### Installation

Add ExDoc to your `mix.exs` dependencies (development only):

```elixir
def deps do
  [
    {:ex_doc, "~> 0.40", only: :dev, runtime: false}
  ]
end
```

Run `mix deps.get` to fetch the dependency.

### Generate Documentation

```bash
mix docs
```

This generates HTML documentation in the `doc/` directory. Open `doc/index.html` in a browser to view.

### Command Line Installation

Alternatively, install as an escript:

```bash
mix escript.install hex ex_doc
```

Then invoke from your project directory after compilation.

## Core Concepts

### Documentation Modules

ExDoc generates documentation from:

- **Module documentation**: Doc strings in `defmodule`, `def`, `defp`, macros
- **Type documentation**: Specs and type definitions
- **Function documentation**: Multiline string comments above functions
- **Examples**: Code examples in doc strings (marked with proper formatting)

### Output Formats

ExDoc supports three output formats:

- **HTML**: Primary format with search, navigation, and responsive design
- **Markdown**: For static site generators or Git-friendly storage
- **EPUB**: E-book format for offline reading on devices

### Key Features

- Offline HTML/Markdown/EPUB generation
- Browser-based smooth page transitions when hosted
- Responsive mobile-friendly design
- Custom pages, guides, livebooks, and cheatsheets
- Full-text and quick-search capabilities
- Source code links for documented entities
- Night mode support
- Auto-linking across modules and functions using backtick syntax
- Keyboard shortcuts (search, navigation)

## Configuration

Configure ExDoc in your `mix.exs` project file under the `docs:` key:

```elixir
def project do
  [
    docs: [
      main: "readme",           # Start page (default: module list)
      logo: "path/to/logo.png", # Logo image path
      extras: ["README.md"],    # Additional markdown files
      groups_for_modules: [],   # Group modules in sidebar
      groups_for_docs: [],      # Group functions by category
      source_url: "https://github.com/...",  # Link to source
      source_ref: "main",       # Git branch for source links
      homepage_url: "https://...", # External link
      api_reference: false,     # Hide API reference section
      proglang: :elixir,        # :elixir or :erlang
      output: "docs"            # Output directory
    ]
  ]
end
```

### Common Configuration Options

| Option                    | Purpose                                | Default     |
| ------------------------- | -------------------------------------- | ----------- |
| `main`                    | Entry page (module name or file path)  | Module list |
| `logo`                    | Logo path (light/dark variant support) | none        |
| `extras`                  | Additional markdown files to include   | `[]`        |
| `groups_for_modules`      | Module grouping rules                  | `[]`        |
| `source_url`              | GitHub/GitLab repository root          | none        |
| `source_ref`              | Git ref for source links (tag/branch)  | none        |
| `homepage_url`            | External project homepage              | none        |
| `proglang`                | `:elixir` or `:erlang`                 | `:elixir`   |
| `output`                  | Output directory                       | `"docs"`    |
| `before_closing_head_tag` | Custom HTML in head                    | none        |
| `before_closing_body_tag` | Custom HTML in body                    | none        |

### Grouping Modules and Functions

Organize documentation output:

```elixir
docs: [
  groups_for_modules: [
    "HTTP": [MyApp.HTTP, MyApp.HTTP.*],
    "Database": [MyApp.DB, MyApp.DB.*]
  ],
  groups_for_docs: [
    "Functions": &(&1[:kind] == :function),
    "Callbacks": &(&1[:kind] == :callback)
  ]
]
```

### Extras (Guides and Pages)

Include markdown files as guides or standalone pages:

```elixir
docs: [
  extras: [
    "README.md": [title: "Home"],
    "guides/introduction.md": [title: "Introduction"],
    "guides/advanced.md": []
  ]
]
```

Files in `guides/` subdirectory automatically become a "Guides" section.

## Best Practices

### Documentation Standards

1. **Module Documentation**: Write concise, descriptive module-level docs

   ```elixir
   defmodule MyApp.User do
     @moduledoc """
     User management and authentication.

     This module provides functions for creating, updating, and deleting users.
     """
   end
   ```

2. **Function Documentation**: Document parameters, return values, and examples

   ```elixir
   @doc """
   Creates a new user with the given email and password.

   ## Parameters
   - `email`: User email address
   - `password`: Plain text password (hashed on storage)

   ## Returns
   `{:ok, user}` on success, `{:error, changeset}` on failure

   ## Examples

       iex> MyApp.User.create("user@example.com", "secret")
       {:ok, %MyApp.User{}}
   """
   def create(email, password) do
     # ...
   end
   ```

3. **Use Backticks for Auto-Linking**: Reference modules and functions
   - `MyApp.User` → links to module
   - `create/2` → links to function
   - `t:user/0` → links to type

4. **Code Examples**: Use `iex>` prefix for runnable examples in docstrings

5. **Type Specifications**: Always include `@spec` for public functions
   ```elixir
   @spec create(String.t(), String.t()) :: {:ok, user()} | {:error, term()}
   def create(email, password) do
     # ...
   end
   ```

### Organization Tips

- Use meaningful module names and organize hierarchically
- Keep related modules in the same namespace
- Group similar functions with consistent naming
- Use `@moduledoc false` to hide internal modules from docs
- Use `@doc false` to hide internal functions
- Create a `README.md` as main entry point
- Add guides in `guides/` directory for conceptual explanations
- Link between modules and functions using backticks

### Common Pitfalls

1. **Missing Specs**: Always include `@spec` for proper type documentation
2. **Poor Examples**: Code examples must be runnable and relevant
3. **Undocumented Callbacks**: Document callback macros with `@callback`
4. **Broken Links**: Check source_url/source_ref configuration for correct links
5. **Inconsistent Structure**: Keep module documentation format consistent
6. **Private Implementation Details**: Hide with `@doc false` appropriately
7. **Missing Extras**: Use guides and README for user-facing documentation

### Testing Generated Docs

```bash
# Generate and serve locally with live reload (requires serving tool)
mix docs

# Test links in generated documentation
# Validate markdown/HTML syntax
```

---

**Version:** 0.40.3  
**Source:** [hexdocs.pm/ex_doc](https://hexdocs.pm/ex_doc/0.40.3)  
**Generated:** 2026-06-17
