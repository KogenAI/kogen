# phoenix_live_reload

Phoenix Live Reload provides live-reload functionality for Phoenix during development. It injects JavaScript with a WebSocket connection to trigger browser refreshes when files change, complementing Phoenix.CodeReloader which recompiles backend code.

## Quick Start

Add to `mix.exs` dependencies:

```elixir
{:phoenix_live_reload, "~> 1.7"}
```

In `config/dev.exs`, configure basic watching:

```elixir
config :phoenix_live_reload,
  patterns: [
    ~r"priv/static/.*(js|css|png|jpeg|jpg|gif|svg)$",
    ~r"priv/gettext/.*(po)$",
    ~r"lib/myapp_web/(live|views)/.*(ex)$",
    ~r"lib/myapp_web/templates/.*(eex)$"
  ]
```

## Core Concepts

**Live Reload Mechanism**: Injects a client-side WebSocket that connects to the development server. When watched files change, the server notifies the client to refresh the browser.

**Watched Patterns**: File patterns determine which changes trigger reloads. Patterns support regex matching for flexibility across assets and templates.

**Backend Watchers**: Multiple filesystem monitoring backends are supported:

- **macOS**: fsevents (built-in)
- **Linux/BSD**: inotify (requires installation)
- **Windows**: inotify-win (built-in)
- **Universal fallback**: `:fs_poll` backend with configurable directory polling

## Configuration

**Core Options** in `config/dev.exs`:

- `interval`: Milliseconds between file checks (default: 100ms). Adjust for performance in large projects.
- `patterns`: List of regex patterns matching files to watch.

**Advanced Features**:

- **Web Console Logger** (Elixir 1.15+): Stream server logs to browser console via `web_console_logger: true`. Useful for debugging SPAs and GraphQL interactions without server logs.

  ```elixir
  config :phoenix_live_reload,
    web_console_logger: true
  ```

- **Editor Integration**: Enable `PLUG_EDITOR` environment variable to jump directly to HEEx component definitions from DOM inspector. Requires VS Code or similar editor setup.

- **CSS Reload Optimization**: Use `data-no-reload` HTML attribute on `<link>` tags for externally-hosted stylesheets to avoid unnecessary reloads:

  ```html
  <link
    rel="stylesheet"
    href="https://cdn.example.com/style.css"
    data-no-reload
  />
  ```

**Directory Polling Fallback**:

```elixir
config :phoenix_live_reload,
  backend: :fs_poll,
  dirs: ["lib", "priv/static"]
```

## Best Practices

1. **Optimize Watched Patterns**: In large projects, specify only necessary directories and file types to reduce polling overhead and improve reload speed.

2. **Use Specific Patterns**: Match exact file extensions and directories rather than broad patterns:

   ```elixir
   ~r"lib/myapp_web/live/.*(ex|html.heex)$"  # Good: specific
   ~r"lib/.*"  # Avoid: too broad
   ```

3. **Exclude Generated Files**: Prevent infinite reload loops by excluding auto-generated output:

   ```elixir
   patterns: [
     ~r"lib/(?!myapp/generated).*"
   ]
   ```

4. **Leverage Server Log Streaming**: Enable `web_console_logger` for real-time debugging of API responses and data flow in single-page applications.

5. **Configure Editor Shortcuts**: Set `PLUG_EDITOR=code` or `PLUG_EDITOR=vim` for rapid navigation between browser DOM and source templates.

6. **Adjust Polling Interval**: Increase `interval` to 500ms or higher if reload frequency causes lag; decrease to 50ms for snappier feedback on fast machines.

7. **Test with Production Assets**: Verify compiled CSS/JavaScript behavior during development by temporarily disabling live reload and checking production builds.

---

**Version:** 1.7.0
**Source:** [hexdocs.pm/phoenix_live_reload](https://hexdocs.pm/phoenix_live_reload/1.7.0)
**Generated:** 2026-08-07
