# esbuild

Elixir package that installs and runs esbuild, a JavaScript bundler and minifier. This package automates esbuild integration in Phoenix projects by handling automatic executable installation and profile-based configuration management.

## Quick Start

### Installation

Add to your `mix.exs` dependencies:

```elixir
{:esbuild, "~> 0.10", only: :dev}
```

Run:

```bash
mix deps.get
```

### Basic Configuration

In your `config/config.exs`:

```elixir
config :esbuild,
  version: "0.17.0",
  default: [
    args: ~w(js/app.js --bundle --target=es2017 --outdir=../priv/static/assets),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => "/usr/local/lib/node_modules"}
  ]
```

### Usage in Phoenix

In `config/dev.exs`, enable file watching:

```elixir
# Cofigure esbuild in dev
config :esbuild,
  default: [
    args: ~w(js/app.js --bundle --target=es2017 --outdir=../priv/static/assets --sourcemap=inline),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => "/usr/local/lib/node_modules"}
  ]

# Watch for changes
if Mix.env() == :dev do
  config :esbuild, :watchers, [
    esbuild: {Esbuild, :install_and_run, [:default, ~w(--watch)]}
  ]
end
```

## Core Concepts

### Profiles

Esbuild uses profiles to manage different bundling configurations:

- **Default Profile**: Named `:default`, used by Phoenix automatically
- **Multiple Profiles**: Create custom profiles for different output targets
- **Profile Configuration**: Each profile accepts `args`, `cd`, and `env` settings

Example with multiple profiles:

```elixir
config :esbuild,
  version: "0.17.0",
  default: [
    args: ~w(js/app.js --bundle --target=es2017 --outdir=../priv/static/assets),
    cd: Path.expand("../assets", __DIR__)
  ],
  admin: [
    args: ~w(js/admin.js --bundle --target=es2017 --outdir=../priv/static/admin),
    cd: Path.expand("../assets", __DIR__)
  ]
```

### Executable Management

- **Automatic Installation**: esbuild executable auto-downloads to `_build` directory
- **Version Locking**: `:version` config specifies exact esbuild version
- **Version Validation**: `:version_check` controls whether version is verified on startup

## Configuration

### Global Settings

| Setting          | Purpose                   | Default                  |
| ---------------- | ------------------------- | ------------------------ |
| `:version`       | esbuild version to use    | required                 |
| `:version_check` | Enable version validation | `true`                   |
| `:path`          | Custom executable path    | auto-managed in `_build` |

### Environment Variables

Override settings with `MIX_ESBUILD_*` environment variables:

```bash
# Use pre-installed esbuild globally
MIX_ESBUILD_PATH=/usr/local/bin/esbuild mix compile
```

### Profile Settings

Each profile accepts:

| Setting | Type     | Description                             |
| ------- | -------- | --------------------------------------- |
| `args`  | `list`   | esbuild command-line arguments          |
| `cd`    | `string` | Working directory for bundling          |
| `env`   | `map`    | Environment variables passed to esbuild |

### Common Arguments

```elixir
# Bundling options
~w(js/app.js --bundle)           # Bundle the file
~w(--target=es2017)              # Target JavaScript version
~w(--outdir=../priv/static)      # Output directory
~w(--sourcemap=inline)           # Include source maps
~w(--minify)                      # Minify output
~w(--watch)                       # Watch for file changes
~w(--loader:.png=dataurl)        # Configure asset loaders
```

## Best Practices

### Development Configuration

Enable inline source maps and file watching for faster debugging:

```elixir
config :esbuild,
  default: [
    args: ~w(js/app.js --bundle --target=es2017 --outdir=../priv/static/assets --sourcemap=inline --watch),
    cd: Path.expand("../assets", __DIR__)
  ]
```

### Production Build

Disable source maps and enable minification:

```elixir
config :esbuild,
  default: [
    args: ~w(js/app.js --bundle --target=es2017 --outdir=../priv/static/assets --minify),
    cd: Path.expand("../assets", __DIR__)
  ]
```

### Multi-Bundle Setup

Organize bundles by feature/section:

```elixir
config :esbuild,
  version: "0.17.0",
  default: [args: ~w(js/app.js --bundle --outdir=../priv/static/assets)],
  admin: [args: ~w(js/admin.js --bundle --outdir=../priv/static/admin)],
  public: [args: ~w(js/public.js --bundle --outdir=../priv/static/public)]
```

### Disable Auto-Installation

If using externally-managed esbuild (system npm, Docker, etc.):

```elixir
config :esbuild,
  version_check: false,
  path: System.get_env("ESBUILD_PATH")
```

### Asset Loader Configuration

Configure how specific file types are handled:

```elixir
args: ~w(
  js/app.js
  --bundle
  --loader:.png=dataurl
  --loader:.svg=text
  --loader:.ttf=file
)
```

### Parallel Bundling

Run multiple profiles in parallel in dev watchers:

```elixir
# config/dev.exs
config :esbuild, :watchers, [
  esbuild_default: {Esbuild, :install_and_run, [:default, ~w(--watch)]},
  esbuild_admin: {Esbuild, :install_and_run, [:admin, ~w(--watch)]}
]
```

### Runtime Function Reference

| Function                                       | Usage                                    |
| ---------------------------------------------- | ---------------------------------------- |
| `Esbuild.install()`                            | Manually install esbuild executable      |
| `Esbuild.install_and_run(profile, extra_args)` | Install if needed, then run              |
| `Esbuild.run(profile, extra_args)`             | Run bundling (assumes installed)         |
| `Esbuild.bin_path()`                           | Get executable path for direct execution |
| `Esbuild.bin_version()`                        | Get installed esbuild version            |
| `Esbuild.config_for!(profile)`                 | Retrieve profile configuration           |
| `Esbuild.configured_version()`                 | Get configured version setting           |

---

**Version:** 0.10.0
**Source:** [hexdocs.pm/esbuild](https://hexdocs.pm/esbuild/)
**Generated:** 2025-10-28
