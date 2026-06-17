# tailwind

Tailwind is a utility-first CSS framework integration for Elixir/Phoenix applications. It provides a convenient Mix task to download, install, and manage Tailwind CSS within your Phoenix project without requiring Node.js.

## Quick Start

### Installation

Add Tailwind to your `mix.exs` dependencies:

```elixir
def deps do
  [
    {:tailwind, "~> 0.5.1"}
  ]
end
```

Run `mix deps.get` to install.

### Initial Setup

In your `config/config.exs`, configure the Tailwind installation:

```elixir
config :tailwind,
  version: "3.0.0",
  default: [
    args: ~w(
      --input=css/app.css
      --output=../priv/static/assets/app.css
    ),
    cd: Path.expand("../assets", __DIR__)
  ]
```

In your `mix.exs`, add Tailwind as a watcher in `aliases`:

```elixir
def project do
  [
    # ...
    aliases: aliases()
  ]
end

defp aliases do
  [
    setup: ["deps.get", "cmd npm install --prefix assets"],
    "assets.deploy": ["tailwind default --minify", "esbuild default --minify"]
  ]
end
```

### Basic CSS Structure

Create `assets/css/app.css`:

```css
@tailwind base;
@tailwind components;
@tailwind utilities;
```

Include generated CSS in your Phoenix layout (typically `lib/app_web/templates/layout/root.html.heex`):

```heex
<link phx-track-static rel="stylesheet" href={~p"/assets/app.css"}>
```

## Core Concepts

### Mix Tasks

**`mix tailwind default`** — Compiles Tailwind CSS using configured settings. Runs once.

**`mix tailwind default --watch`** — Watches for CSS file changes and recompiles automatically. Used during development.

**`mix tailwind default --minify`** — Compiles with minification for production.

**`mix tailwind.install`** — Downloads and installs the Tailwind CLI executable for your platform.

### Configuration Structure

The `:tailwind` application config accepts:

- `version`: Tailwind CSS version to download (e.g., "3.0.0")
- `default`: Named profile with Mix task options
  - `args`: CLI arguments passed to Tailwind binary
  - `cd`: Working directory for compilation

### Multiple Profiles

Support multiple Tailwind configurations by adding additional profiles:

```elixir
config :tailwind,
  version: "3.0.0",
  default: [...],
  admin: [
    args: ~w(--input=css/admin.css --output=../priv/static/assets/admin.css),
    cd: Path.expand("../assets", __DIR__)
  ]
```

Access with: `mix tailwind admin --watch`

## Configuration

### Path Conventions

- **Input**: CSS source files typically in `assets/css/`
- **Output**: Compiled CSS to `priv/static/assets/`
- **Content**: Configure Tailwind's content scanning in `assets/tailwind.config.js`

### Tailwind Config File

Create `assets/tailwind.config.js` for Tailwind-specific settings:

```javascript
module.exports = {
  content: [
    "./js/**/*.js",
    "../lib/**/*_web.{heex,ex}",
    "../lib/**/*.{heex,ex}",
  ],
  theme: {
    extend: {
      colors: {
        // Custom colors
      },
    },
  },
  plugins: [],
};
```

### Environment-Specific Settings

For production, use minification flag:

```elixir
# In config/prod.exs
config :tailwind,
  version: "3.0.0",
  default: [
    args: ~w(--input=css/app.css --output=../priv/static/assets/app.css --minify),
    cd: Path.expand("../assets", __DIR__)
  ]
```

### Watcher Integration (dev.exs)

```elixir
config :hello, HelloWeb.Endpoint,
  watchers: [
    tailwind: {Tailwind.CLI, :run, [args: ["default", "--watch"]]}
  ]
```

## Best Practices

### Development Workflow

1. **Start watchers** with `mix phx.server` — automatically watches CSS and recompiles
2. **Use HEX class names** in `.heex` templates without quotation escaping
3. **Keep CSS modular** — organize `assets/css/` by component or feature
4. **Leverage @apply** for component classes in CSS instead of JavaScript

### Performance Optimization

- Always **minify for production** using `--minify` flag
- Use **PurgeCSS integration** (Tailwind handles this with content config)
- **Separate vendor CSS** if using third-party components
- **Cache busted assets** — Phoenix automatically handles static asset versioning

### Common Patterns

**Responsive Typography:**

```heex
<h1 class="text-lg sm:text-xl md:text-2xl lg:text-3xl">
  Responsive Heading
</h1>
```

**Conditional Styling:**

```heex
<div class={[
  "base-classes",
  @active && "active-classes"
]}>
  Content
</div>
```

**Dark Mode Support:**
Configure in `tailwind.config.js`:

```javascript
module.exports = {
  darkMode: "class",
  // ...
};
```

### Gotchas

1. **Content paths must be exact** — misconfigured content globs prevent class purging
2. **Mix task output path** must align with Phoenix static asset serving directory
3. **Version mismatch** — ensure `config.exs` version matches `package.json` if mixing with Node
4. **File watching delays** — CSS may not immediately reflect changes; check console for compilation errors
5. **Minification in dev** — avoid `--minify` during development; use only in production config

### Troubleshooting

**CSS not updating:**

- Verify `content` paths in `tailwind.config.js` match your template locations
- Check watcher is running: `mix tailwind default --watch`
- Clear `priv/static/` and rebuild

**Classes not applied:**

- Ensure CSS file is linked in layout template
- Verify class names are in content scanning paths
- Check for typos in class names (Tailwind doesn't warn about unknown utilities)

**Build failures:**

- Run `mix tailwind.install` to ensure CLI binary is downloaded
- Check file permissions on `assets/` directory
- Verify `cd` path in config is correct

---

**Version:** 0.5.1  
**Source:** hexdocs.pm/tailwind  
**Generated:** 2026-06-17
