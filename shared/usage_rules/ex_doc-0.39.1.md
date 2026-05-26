# ex_doc

ExDoc is a documentation generation tool that transforms API documentation and guides into offline-accessible HTML and EPUB formats with full-text search, keyboard shortcuts, and night mode support.

## Quick Start

### Installation

Add ex_doc as a development dependency in `mix.exs`:

```elixir
{:ex_doc, "~> 0.39", only: :dev, runtime: false}
```

Requires Elixir v1.15 or later.

### Generate Documentation

```bash
mix docs
```

This generates HTML documentation in the `doc/` directory (configurable via `:output` option).

## Core Concepts

### Supported Content Formats

- **Markdown** (`.md`) - Module documentation and guides
- **Cheatsheets** (`.cheatmd`) - Quick reference guides
- **Livebooks** (`.livemd`) - Interactive tutorials and examples
- **API docs** - Auto-extracted from module code documentation

### Key Features

- **Offline access** - Generate complete HTML/EPUB documentation
- **Responsive design** - Works on phones, tablets, desktops
- **Full-text search** - Client-side search across all documentation
- **Night mode** - Browser preference-based dark mode support
- **Module tooltips** - Cross-project function and module references
- **Version management** - Support for multiple documentation versions
- **Custom pages** - Add guides beyond API documentation

## Configuration

Configure in `project/0` of `mix.exs`:

```elixir
def project do
  [
    name: "MyProject",              # Required: Display name
    docs: [
      output: "doc",                # Output directory
      logo: "assets/logo.png",      # Project logo
      source_url: "https://github.com/user/repo",
      homepage_url: "https://example.com",
      source_ref: "main",
      extra_section: "GUIDES",      # Custom section name
      groups_for_modules: [         # Group modules by category
        "Database": ~r/^MyApp\.DB\./,
        "Web": ~r/^MyApp\.Web\./
      ],
      groups_for_extras: [          # Group guides
        "Getting Started": ~r/intro/,
        "Advanced": ~r/advanced/
      ]
    ]
  ]
end
```

### Common Options

- `:output` - Documentation output directory (default: `doc/`)
- `:logo` - Project logo image path
- `:source_url` - GitHub/source repository URL
- `:homepage_url` - Project website URL
- `:before_closing_head_tag` - Custom HTML before `</head>` (CSS/JS)
- `:before_closing_body_tag` - Custom HTML before `</body>`
- `:formatters` - Custom document formatters
- `:skip_undefined_reference_warnings` - Suppress warnings for cross-module refs

## Best Practices

### Documentation Structure

- **Module docs** - Write clear docstrings explaining purpose and usage
- **Function docs** - Document parameters, return values, and examples
- **Examples in docs** - Use `## Examples` section with runnable code
- **Guide organization** - Use guides for tutorials, not API reference

### Content Guidelines

- Keep guides separate from API docs (use `:extra_section`)
- Group related modules with `groups_for_modules` for navigation
- Include examples in docstrings using `iex>` code blocks for testability
- Link to related modules using standard module references

### Generation Workflow

1. Write module and function documentation as comments
2. Create guide files (`.md`, `.livemd`) in designated directory
3. Configure doc options in `mix.exs`
4. Run `mix docs` to generate
5. Check `doc/index.html` in browser
6. Iterate until documentation is clear and complete

### Integration

- Deploy generated docs to static hosting (GitHub Pages, ReadTheDocs)
- Include link to ExDoc source on all rendered documentation (Apache 2 license requirement)
- Regenerate docs on release as part of CI/CD pipeline

---

**Version:** 0.39.1
**Source:** [hexdocs.pm/ex_doc](https://hexdocs.pm/ex_doc/0.39.1/)
**Generated:** 2025-10-28
