# phoenix_live_reload

Phoenix Live-Reload provides automatic browser reloading and asset updates during development. It injects a WebSocket client that watches the filesystem and refreshes the browser when files change—CSS reloads instantly without page refresh, and full reloads trigger when Elixir code or templates change.

## Quick Start

**Installation**
Add to `mix.exs`:

```elixir
{:phoenix_live_reload, "~> 1.6"}
```

**Basic Configuration** in `config/dev.exs`:

```elixir
config :my_app, MyAppWeb.Endpoint,
  live_reload: [
    interval: 1000,
    patterns: [
      ~r"priv/static/.*(js|css|png|jpeg|jpg|gif|svg)$",
      ~r"priv/gettext/.*(po)$",
      ~r"lib/my_app_web/(live|views)/.+\.ex$",
      ~r"lib/my_app_web/templates/.+\.eex$"
    ]
  ]
```

The endpoint automatically loads the live-reload JavaScript and WebSocket connection during development.

## Core Concepts

**Filesystem Watching**
Live-Reload monitors file changes using pluggable backends:

- **fsevents** (macOS): Native, zero-delay file monitoring
- **inotify** (Linux/BSD): Kernel-level file monitoring (install via package manager)
- **inotify-win** (Windows): Native Windows file monitoring
- **:fs_poll** (universal fallback): Polling-based fallback when native watchers unavailable

**Three Reload Types**

1. **CSS Reload** — Stylesheets inject without page refresh. Use `data-no-reload="true"` on `<link>` tags to exempt remote stylesheets from reload.

2. **Asset Update** — JavaScript, images, and other static files refresh via cache-busting.

3. **Full Page Reload** — Triggered when Elixir code, EEx templates, or LiveView files change (via Phoenix.CodeReloader coordination).

**WebSocket Connection**
A persistent WebSocket connects the browser to the dev server. The client polls for changes via `change_url` endpoint; the server pushes notifications when watched files modify.

## Configuration

**Interval**

```elixir
live_reload: [interval: 1000]  # milliseconds; default 100
```

Debounces rapid file changes (e.g., during Save All). Higher intervals reduce server load during active editing.

**Patterns**

```elixir
patterns: [
  ~r"priv/static/.+\.(js|css|png|svg)$",
  ~r"lib/my_app_web/live/.+\.ex$",
  ~r"lib/my_app_web/templates/.+\.eex$"
]
```

Regex patterns filter which files trigger reload. Broader patterns = more updates; narrow patterns = fewer false refreshes.

**Backend Selection**

```elixir
config :phoenix_live_reload, backend: :fs_poll
```

Override the default watcher backend. Use `:fs_poll` if native watchers fail or are unavailable.

**Server Log Streaming** (Elixir 1.15+)

```elixir
config :my_app, MyAppWeb.Endpoint,
  live_reload: [
    web_console_logger: true
  ]
```

Enable with `web_console_logger: true`, then call `reloader.enableServerLogs()` in browser console to stream terminal logs to browser DevTools.

**Editor Integration**
Set `PLUG_EDITOR` environment variable to jump to source:

```bash
export PLUG_EDITOR="code"  # VS Code
export PLUG_EDITOR="vim"   # Vim
```

Click elements with alt+c (HEEx component) or alt+d (component caller) to open the source file.

## Best Practices

**Pattern Tuning**

- Include all asset types your app uses (fonts, videos, webp, etc.) in patterns
- Exclude `node_modules` and build artifacts to prevent false reloads
- Test patterns against your directory structure before deployment

**Interval Tuning**

- Default 100ms is responsive for single-file saves
- Increase to 500ms–1000ms if file watchers spam events (slower systems)
- Decrease below 100ms only if you need sub-100ms responsiveness (rare)

**Disabling for Specific Files**
Add `data-no-reload="true"` to external stylesheets or resource tags to exempt them:

```html
<link
  rel="stylesheet"
  href="https://cdn.example.com/styles.css"
  data-no-reload="true"
/>
```

**Coordinating with Phoenix.CodeReloader**
Live-Reload handles browser refresh; `Phoenix.CodeReloader` (separate process) recompiles Elixir code. Both run in development automatically—no manual coordination needed. CodeReloader changes trigger Live-Reload full reloads.

**Debugging File Watching**
If changes don't trigger reload:

1. Check console for WebSocket connection errors
2. Verify file pattern matches the changed file path
3. Confirm `:phoenix_live_reload` is listed in `mix.exs` and not skipped by `only: :test`
4. Test with `interval: 5000` to rule out debounce hiding the change

**Production Exclusion**
Live-Reload is dev-only. The `:phoenix_live_reload` dependency should be in `only: :dev` or skipped entirely in production. Standard mix.exs convention handles this automatically.

---

**Version:** 1.6.2
**Source:** [hexdocs.pm/phoenix_live_reload](https://hexdocs.pm/phoenix_live_reload/)
**Generated:** 2026-04-25
