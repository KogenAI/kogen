# tailwind

Tailwind is an Elixir package that provides automated installer and runner for the Tailwind CSS framework. It manages the Tailwind executable automatically for Phoenix and other Elixir projects, handling version management, multi-profile configurations, and seamless integration with your build pipeline.

## Quick Start

### Installation

Add tailwind to your `mix.exs` dependencies:

```elixir
def deps do
  [
    {:tailwind, "~> 0.4"}
  ]
end
```

Run `mix deps.get` to install. The package will automatically download and manage the appropriate Tailwind CSS executable for your system during the build process.

### Basic Configuration

Configure in `config/config.exs`:

```elixir
config :tailwind,
  version: "4.1",
  path: "./node_modules/.bin/tailwind"
```

### Running Tailwind

Tailwind integrates with Phoenix's asset pipeline. It watches and processes CSS files automatically during development. For production builds, it minifies CSS output.

## Core Concepts

### Automatic Executable Management

Tailwind automatically downloads, installs, and manages the correct executable version for your operating system and architecture. No manual npm installation required unless you prefer external management.

**Version Handling**: The current default version is 4.1.12. You can specify a different version in config. Version checking is enabled by default but can be disabled if you manage Tailwind externally (via npm or similar).

### Profile System

Define multiple Tailwind profiles beyond the default for different build scenarios:

```elixir
config :tailwind,
  default: [
    args: ~w(--input css/app.css --output priv/static/assets/app.css),
    cd: Path.expand("../", __DIR__)
  ],
  minified: [
    args: ~w(--input css/app.css --output priv/static/assets/app.css --minify),
    cd: Path.expand("../", __DIR__)
  ]
```

Each profile can have:

- **args**: Command-line arguments passed to Tailwind
- **cd**: Working directory for execution
- **env**: Custom environment variables

### Key Functions

- `Tailwind.bin_path()` - Returns path to the installed Tailwind executable
- `Tailwind.configured_version()` - Returns configured version string
- `Tailwind.install_and_run/2` - Installs executable if needed, then runs with profile and args
- `Tailwind.run/2` - Executes Tailwind with specified profile and additional arguments

## Configuration

### Global Settings

```elixir
config :tailwind,
  version: "4.1.12",              # Tailwind CSS version to use
  version_check: true,            # Check version compatibility (can disable for external management)
  path: "./node_modules/.bin/tailwind",  # Custom executable path (if managing externally)
  target: :arm64                  # System architecture (auto-detected if not set)
```

### Profile Configuration

Define execution profiles in `config/dev.exs` and `config/prod.exs`:

```elixir
config :tailwind,
  default: [
    args: ~w(--input css/app.css --output priv/static/assets/app.css --watch),
    cd: Path.expand("../", __DIR__)
  ]
```

### External Tailwind Management

If managing Tailwind via npm or another package manager:

```elixir
config :tailwind,
  version_check: false,  # Disable automatic version verification
  path: "./node_modules/.bin/tailwind"  # Point to external executable
```

## Best Practices

### Development vs Production

Use different profiles for development and production builds:

- **Development**: Enable `--watch` flag for live CSS updates
- **Production**: Enable `--minify` flag to reduce CSS file size

### Configuration Organization

Keep Tailwind configuration in `config/config.exs` for global settings and environment-specific configs in `config/dev.exs` and `config/prod.exs`.

### Version Management

Let Tailwind handle version management automatically unless you have specific requirements for external management. This simplifies dependency tracking and ensures consistency.

### Multi-Profile Usage

Use profiles for different build scenarios:

- Standard development with watch mode
- Minified production builds
- CSS extraction for specific components
- Custom processing pipelines

### Architecture Considerations

The package auto-detects system architecture (x86_64, arm64, etc.). Explicitly set `:target` only if auto-detection fails or you need a specific version.

### Integration with Phoenix

Tailwind integrates seamlessly with Phoenix's `assets/` directory. Configure input/output paths relative to your project structure. Watch mode works automatically during development with `mix phx.server`.

---

**Version:** 0.4.1
**Source:** [hexdocs.pm/tailwind](https://hexdocs.pm/tailwind/)
**Generated:** 2025-11-04
