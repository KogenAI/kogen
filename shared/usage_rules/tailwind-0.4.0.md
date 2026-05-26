# Tailwind

Tailwind is an Elixir installer and runner for the Tailwind CSS framework. It manages automatic downloading of the Tailwind executable and integrates seamlessly with Phoenix projects through Mix tasks.

## Quick Start

### Installation

Add to `mix.exs` dependencies:

```elixir
{:tailwind, "~> 0.4"}
```

Install the executable:

```bash
mix tailwind.install
```

### Basic Configuration

Add to `config/config.exs`:

```elixir
config :tailwind,
  version: "4.1.12",
  default: [
    args: ~w(--input=css/app.css --output=../priv/static/assets/app.css),
    cd: Path.expand("../assets", __DIR__)
  ]
```

### Running Tailwind

```bash
mix tailwind default
```

Add to `config/dev.exs` for watch mode:

```elixir
config :tailwind,
  default: [
    args: ~w(--input=css/app.css --output=../priv/static/assets/app.css --watch),
    cd: Path.expand("../assets", __DIR__)
  ]
```

## Core Concepts

### Profiles

Tailwind supports multiple profiles for different configurations. The default profile is `:default`. Each profile can have:

- **`args`** — command-line arguments passed to the Tailwind executable
- **`cd`** — working directory for execution
- **Environment variables** — custom variables for the process

### Automatic Installation

When you run `mix tailwind`, the executable is automatically downloaded if not present. The package auto-detects your system architecture (auto-detected target).

### Version Management

The `:version` configuration specifies which Tailwind release to use. By default, version 4.1.12 is installed. Use `version_check: false` if managing versions externally (e.g., via npm).

### Two Generation Approaches

**Tailwind v3**: Requires explicit config file path

```bash
mix tailwind default -- --config=tailwind.config.js
```

**Tailwind v4**: Uses input CSS file with `@import` statements

```bash
mix tailwind default -- --input=css/app.css --output=css/app.generated.css
```

## Configuration

### Global Options

Four global configuration keys control Tailwind behavior:

- **`:version`** — Specifies the Tailwind version to install/use
- **`:version_check`** — Set to `false` to skip version verification (useful with npm)
- **`:path`** — Custom path to the executable (auto-managed by default)
- **`:target`** — System architecture (auto-detected by default)

### Profile Configuration

Define profiles in config files:

```elixir
config :tailwind,
  default: [
    args: ~w(--input=css/app.css --output=../priv/static/assets/app.css),
    cd: Path.expand("../assets", __DIR__)
  ],
  production: [
    args: ~w(--input=css/app.css --output=../priv/static/assets/app.css --minify),
    cd: Path.expand("../assets", __DIR__)
  ]
```

### NPM Integration

To use npm-managed Tailwind instead of auto-download:

```elixir
config :tailwind,
  version_check: false,
  default: [
    args: ~w(--input=css/app.css --output=../priv/static/assets/app.css),
    cd: Path.expand("../assets", __DIR__),
    path: Path.expand("../../node_modules/.bin/tailwindcss", __DIR__)
  ]
```

### Custom Installation Source

For unsupported platforms, install from custom URL:

```bash
mix tailwind.install https://custom-url/tailwindcss-platform-arch
```

## Mix Tasks

### mix tailwind

Invokes Tailwind with specified arguments:

```bash
mix tailwind PROFILE [TAILWIND_ARGS]
mix tailwind default --minify
```

Arguments are appended to any pre-configured args. Automatically downloads Tailwind if missing.

**Options**:

- `--runtime-config` — Load runtime configuration before execution

### mix tailwind.install

Installs the Tailwind executable:

```bash
mix tailwind.install
mix tailwind.install --if-missing
```

**Options**:

- `--if-missing` — Only install if version not already present
- `--runtime-config` — Load runtime configuration before execution

## Best Practices

### Development vs Production

Use separate profiles for different environments:

```elixir
# config/dev.exs
config :tailwind,
  default: [args: ~w(...--watch)]

# config/prod.exs
config :tailwind,
  default: [args: ~w(...--minify)]
```

### Phoenix Integration

For automatic Tailwind watching during development, add to `config/dev.exs`:

```elixir
watchers: [
  tailwind: {Tailwind, :run, [:default, []]}
]
```

### LiveView Class Names

The default Tailwind installation includes Phoenix-specific variant classes:

- `phx-no-feedback`
- `phx-click-loading`
- `phx-submit-loading`
- `phx-change-loading`

These support Tailwind styling during Phoenix LiveView lifecycle events.

### Input/Output Structure

**v4 projects**: Use CSS input files with `@import` statements:

```css
/* assets/css/app.css */
@import "tailwindcss";

/* Your custom styles */
```

**v3 projects**: Use explicit Tailwind config file and reference it in args.

### Error Handling

If Tailwind fails to install automatically, manually install with:

```bash
mix tailwind.install
```

Or specify a custom source for your platform.

---

**Version:** 0.4.0
**Source:** [hexdocs.pm/tailwind](https://hexdocs.pm/tailwind/)
**Generated:** 2025-10-28
