# phoenix_live_reload

Phoenix Live-Reload is a development tool that injects JavaScript into your page with a WebSocket connection to the server, enabling automatic browser reloading when you modify project files during development. This is complementary to Phoenix.CodeReloader, which recompiles Elixir code.

## Quick Start

### Installation

Add to your `mix.exs` dependencies:

```elixir
def deps do
  [
    {:phoenix_live_reload, "~> 1.6"}
  ]
end
```

Then run `mix deps.get`.

### Basic Configuration

Enable in `config/dev.exs`:

```elixir
config :my_app, MyAppWeb.Endpoint,
  live_reload: [
    interval: 100,  # milliseconds, default
    patterns: [
      ~r"priv/static/.+",
      ~r"lib/my_app_web/live/.+",
      ~r"lib/my_app_web/templates/.+",
      ~r"lib/my_app_web/components/.+\.heex$"
    ]
  ]
```

## Core Concepts

### File Watching & Reloading

Live-Reload watches filesystem changes and triggers targeted reloads:

- **CSS files**: Reload stylesheets without full page refresh
- **Templates & Components**: Reload HEEx templates and LiveView components
- **Static Assets**: Reload JavaScript and images automatically

### Backend Watchers

Configure the filesystem watcher in `config/config.exs`:

**Platform-Specific Defaults**:

- **Linux/BSD**: inotify (requires installation: `inotify-tools`)
- **Windows**: inotify-win (built-in)
- **macOS**: fsevents (built-in)
- **Fallback**: `:fs_poll` (polling-based, works universally but slower)

### Relationship to Phoenix.CodeReloader

- **CodeReloader**: Recompiles Elixir code when `.ex`/`.exs` files change
- **Live-Reload**: Reloads frontend assets (CSS, JavaScript, templates) - NOT Elixir code
- **Together**: Both run in development for complete hot-reload experience

## Configuration

### Reload Patterns

Define which files trigger reloads:

```elixir
patterns: [
  ~r"priv/static/.+",
  ~r"lib/my_app_web/(live|templates|components)/.+",
  ~r"lib/my_app_web/.+\.html$"
]
```

### Reload Interval

Set poll interval (in milliseconds):

```elixir
live_reload: [
  interval: 500,  # Check for changes every 500ms
  patterns: [...]
]
```

### Backend Configuration

Override default backend in `config/config.exs`:

```elixir
config :phoenix_live_reload,
  backend: :fs_poll,  # Use polling instead of inotify
  dirs: ["priv/static", "lib/my_app_web/live"],
  backend_opts: [interval: 500]
```

### Web Console Logger (Elixir 1.15+)

Stream server logs to browser console during development:

```elixir
config :my_app, MyAppWeb.Endpoint,
  live_reload: [
    web_console_logger: true,
    patterns: [...]
  ]
```

Enable in your page layout:

```javascript
// Enable after page loads
document.addEventListener("phx:page-loading-stop", () => {
  if (window.reloader) {
    reloader.enableServerLogs();
  }
});
```

### Editor Integration

Jump directly from HTML elements in browser to source code:

```bash
export PLUG_EDITOR="vscode://file/__FILE__:__LINE__"
```

Then in dev environment, clicking elements opens your editor at the source location.

## Best Practices

### CSS Reloading Optimization

Prevent remote stylesheets from blocking reload:

```html
<link rel="stylesheet" href="//cdn.example.com/style.css" data-no-reload />
```

Live-Reload will reload local stylesheets without full page refresh.

### Pattern Matching Efficiency

Be specific with patterns to avoid excessive reloads:

```elixir
# ✅ Efficient - targets specific directories
patterns: [
  ~r"priv/static/(css|js)/.+",
  ~r"lib/my_app_web/(live|components)/.+"
]

# ❌ Inefficient - too broad, reloads on non-code changes
patterns: [~r".+"]
```

### Development vs. Production

Live-Reload only runs in `:dev` environment. In `config/dev.exs`:

```elixir
config :my_app, MyAppWeb.Endpoint, live_reload: [...]
```

In `config/prod.exs`, leave it unconfigured (plug is never loaded).

### Troubleshooting Missed Reloads

If changes aren't detected:

1. **Check patterns**: Ensure file paths match configured patterns
2. **Verify backend**: Confirm inotify or fsevents is available: `mix phx.server --verbose`
3. **Try polling**: Fallback to `:fs_poll` if watcher fails:
   ```elixir
   config :phoenix_live_reload, backend: :fs_poll
   ```
4. **Check interval**: Increase interval if system is slow:
   ```elixir
   live_reload: [interval: 500, ...]
   ```

### Combining with LiveView

For LiveView components, ensure patterns include component files:

```elixir
patterns: [
  ~r"lib/my_app_web/live/.+\.ex$",
  ~r"lib/my_app_web/live/.+\.heex$"
]
```

Note: Elixir `.ex` changes require CodeReloader; `.heex` template changes trigger live_reload.

---

**Version:** 1.6.1
**Source:** [hexdocs.pm/phoenix_live_reload](https://hexdocs.pm/phoenix_live_reload/)
**Generated:** 2025-10-28
