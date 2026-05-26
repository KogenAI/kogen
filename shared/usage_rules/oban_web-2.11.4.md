# oban_web

A self-contained dashboard for monitoring and managing Oban job queues with Phoenix LiveView. Provides real-time visibility into queue status, job history, and performance metrics.

## Quick Start

### Installation

Add to `mix.exs`:

```elixir
{:oban_web, "~> 2.11"}
```

### Automatic Setup

With Igniter (recommended):

```bash
mix igniter.install oban_web
# or
mix oban_web.install
```

### Manual Setup

Mount in your router:

```elixir
import Oban.Web.Router

scope "/" do
  pipe_through :browser
  oban_dashboard "/oban"
end
```

**Prerequisites:**

- Oban installed and configured
- Phoenix LiveView installed and working

## Core Concepts

### Dashboard Access

The `oban_dashboard/2` macro provides a web interface at the specified path (e.g., `/oban`). Default configuration mounts without authentication - **always restrict in production**.

### Access Control

Two approaches:

1. **Custom Resolver**: Implement `Oban.Web.Resolver` callback to enforce per-user controls
2. **Basic Auth**: Use middleware or custom pipe_through to gate the route

Example read-only resolver:

```elixir
defmodule MyApp.ObanResolver do
  @behaviour Oban.Web.Resolver

  def resolve_access(_socket), do: :read_only
end
```

### Multi-Instance Support

Mount multiple dashboards for different Oban instances:

```elixir
oban_dashboard "/oban/primary", oban_name: :oban
oban_dashboard "/oban/analytics", oban_name: :oban_analytics
```

## Configuration

### Core Options

- `:resolver` - Module implementing `Oban.Web.Resolver` for access control and customization
- `:oban_name` - Atom specifying Oban instance (defaults to primary)
- `:as` - Customizes route name identifier
- `:socket_path` - Overrides default "/live" socket endpoint

### Communication Options

- `:transport` - Transport mode: `"websocket"` (default) or `"longpoll"` (for environments without WebSocket)

### Security Options

- `:csp_nonce_assign_key` - Implements Content Security Policy:

  ```elixir
  # Single nonce for all assets
  csp_nonce_assign_key: :csp_nonce

  # Separate nonces per asset type
  csp_nonce_assign_key: %{img: :img_nonce, style: :style_nonce, script: :script_nonce}
  ```

### Lifecycle Hooks

- `:on_mount` - Attaches custom hooks to mount callbacks (e.g., user-fetching, activation checks). Prepended before Oban Web's built-in authentication.

### Complete Example

```elixir
oban_dashboard "/oban",
  resolver: MyApp.ObanResolver,
  oban_name: :oban,
  csp_nonce_assign_key: :csp_nonce,
  on_mount: {MyApp.ObanHooks, :auth}
```

## Best Practices

### Performance & Notifiers

**Postgres Notifier (default):** Works out-of-the-box but can impact database under high job volumes.

**PG Notifier (recommended for production):**

- Significantly better performance
- Requires clustered deployment (all app nodes connected)
- Configure in Oban setup: `notifier: Oban.Notifiers.PG`

### Security

1. **Always restrict access** - Never expose dashboard publicly without authentication
2. **Use read-only mode** in production if monitoring only: return `:read_only` from resolver
3. **Implement CSP nonces** for stricter security policies
4. **Custom resolvers** for role-based access (e.g., admin-only, read-only for viewers)

### Multi-Deployment Architectures

For web/worker separation:

- Add `oban_met` dependency for accurate metrics across architecture
- Mount dashboard in web application only
- Use PG notifier for inter-process communication

### Development vs Production

```elixir
# Development: permissive
oban_dashboard "/oban"

# Production: restrictive
oban_dashboard "/oban",
  resolver: MyApp.ObanResolver,
  transport: System.get_env("WEBSOCKET_ENABLED", "true") == "true" && "websocket" || "longpoll"
```

### Monitoring Job Queues

1. Visit dashboard to view real-time queue status
2. Check job history for failures and patterns
3. Monitor metrics for performance degradation
4. Use resolver callbacks for custom business logic (e.g., alerts)

---

**Version:** 2.11.4
**Source:** [hexdocs.pm/oban_web](https://hexdocs.pm/oban_web/)
**Generated:** 2025-10-28
