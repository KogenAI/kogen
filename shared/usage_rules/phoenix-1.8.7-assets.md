# Phoenix - Asset Management

## Asset Pipeline Overview

Phoenix v1.7+ uses **esbuild** for JavaScript bundling and **Tailwind CSS** for stylesheet compilation without requiring Node.js as a system dependency. JavaScript processes from `assets/js/app.js` to `priv/static/assets/js/app.js` with automatic recompilation in development via `mix phx.server` and deployment via `mix assets.deploy` in production.

## esbuild Configuration

Configure esbuild in `config/config.exs`:

```elixir
config :esbuild,
  version: "0.20.0",
  default: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]
```

External resources (`/fonts/*`, `/images/*`) prevent bundler errors when images and fonts are referenced in CSS or HTML but served statically.

## JavaScript Dependencies

Three approaches for integrating third-party packages:

### Vendor Locally

Include source files directly in the project:

```javascript
// assets/js/vendor/topbar.js
// (local copy of library)

// assets/js/app.js
import { topbar } from "./vendor/topbar";
```

### NPM Installation

Install via npm with the `--prefix` flag:

```bash
npm install topbar --prefix assets
```

Import by package name:

```javascript
import * as topbar from "topbar";
```

### Mix Dependencies (Recommended)

Track as git dependencies in `mix.exs` to avoid system Node.js:

```elixir
defp deps do
  [
    {:heroicons, "~> 0.5"}
  ]
end
```

Configure esbuild to include the dependency:

```elixir
config :esbuild,
  default: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]
```

Import from the dependency:

```javascript
import { CheckIcon } from "heroicons/solid";
```

This approach is recommended for new applications to avoid vendoring large icon/component libraries.

## Tailwind CSS Setup

Configure Tailwind in `config/config.exs`:

```elixir
config :tailwind,
  version: "3.4.0",
  default: [
    args: ~w(
      --config=tailwind.config.js
      --input=css/app.css
      --output=../priv/static/assets/css/app.css
    ),
    cd: Path.expand("../assets", __DIR__)
  ]
```

Create `assets/tailwind.config.js`:

```javascript
module.exports = {
  content: ["./js/**/*.js", "../lib/*_web.ex", "../lib/*_web/**/*.ex"],
  theme: {
    extend: {},
  },
  plugins: [],
};
```

The `content` paths tell Tailwind which files to scan for used classes, enabling tree-shaking to reduce CSS bundle size.

## Static Files & External Resources

Images and fonts require special handling in esbuild to avoid bundling errors.

### Serving Static Assets

Static files in `priv/static/` are automatically served by Phoenix:

```
priv/static/
  css/
  js/
  images/
    logo.png
  fonts/
    custom.woff2
```

Reference in templates:

```heex
<img src="/images/logo.png" />
<link rel="stylesheet" href="/fonts/custom.css" />
```

### Asset Digests

In production, run `mix assets.deploy` to add content-based digests to filenames:

```
priv/static/assets/
  css/app.HASH.css
  js/app.HASH.js
```

The manifest file (`priv/static/assets/cache_manifest.json`) maps original names to digested versions. Phoenix automatically references the digested versions in production.

## Development Workflow

Start the development server:

```bash
mix phx.server
```

The server automatically watches and recompiles:

- `assets/js/app.js` → via esbuild
- `assets/css/app.css` → via Tailwind
- `lib/*_web/templates/` → HEEx templates

Changes appear immediately after page refresh (or with LiveView, without refresh).

## Production Deployment

Compile assets for production:

```bash
MIX_ENV=prod mix assets.deploy
```

This:

1. Minifies JavaScript and CSS
2. Adds content hashes to filenames
3. Generates `priv/static/assets/cache_manifest.json`
4. Optionally gzip-compresses assets

Include in deployment scripts before starting the server:

```bash
MIX_ENV=prod mix assets.deploy
MIX_ENV=prod mix phx.server
```

## Customization

### Alternative CSS Frameworks

Replace Tailwind with Bootstrap, Bulma, or others by:

1. Removing Tailwind from `mix.exs`
2. Removing `config :tailwind`
3. Installing CSS framework via npm or as Mix dependency
4. Importing in `assets/css/app.css`:

```css
@import "~bootstrap/css/bootstrap";
```

### Custom esbuild Plugins

Replace the default esbuild configuration with a custom Node.js build script:

1. Create `assets/build.js`:

```javascript
const esbuild = require("esbuild");

esbuild
  .build({
    entryPoints: ["js/app.js"],
    bundle: true,
    outdir: "../priv/static/assets/js",
    // custom plugins
    plugins: [
      /* your plugins */
    ],
  })
  .catch(() => process.exit(1));
```

2. Update `config/config.exs`:

```elixir
config :esbuild,
  default: [
    args: ~w(build.js),
    cd: Path.expand("../assets", __DIR__)
  ]
```

### Environment-Specific Builds

Define separate esbuild profiles in `mix.exs`:

```elixir
def project do
  [
    # ...
    aliases: aliases()
  ]
end

def aliases do
  [
    "assets.build": ["esbuild default"],
    "assets.deploy": ["esbuild default", "phx.digest"]
  ]
end
```

---

[← Back to main](phoenix-1.8.7.md)
**Version:** 1.8.7
