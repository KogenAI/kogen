# phoenix_live_dashboard

Real-time performance monitoring and debugging dashboard for Phoenix applications. Built on LiveView, provides system visibility across connected Erlang nodes with metrics, monitoring, and diagnostics.

## Quick Start

### Installation

Add to `mix.exs` dependencies:

```elixir
{:phoenix_live_dashboard, "~> 0.8"}
```

### Basic Setup

1. **Configure LiveView** in `config/config.exs`:

   ```elixir
   config :phoenix_live_view, :signing_salt, "salt_value_here"
   ```

2. **Add LiveView socket** in your endpoint (`lib/myapp_web/endpoint.ex`):

   ```elixir
   socket "/live", Phoenix.LiveView.Socket
   ```

3. **Add routes** in your router (`lib/myapp_web/router.ex`):

   ```elixir
   import Phoenix.LiveDashboard.Router

   scope "/dashboard" do
     pipe_through :browser
     live_dashboard "/", metrics: MyAppWeb.Telemetry
   end
   ```

## Core Concepts

### Dashboard Modules

The dashboard provides nine primary monitoring modules:

1. **Home** - System overview and statistics
2. **OS Data** - CPU, memory, and disk usage metrics
3. **Metrics** - Real-time telemetry event visualization with charts
4. **Request Logging** - Per-request HTTP logging and details
5. **Applications** - Node applications and supervision tree inspection
6. **Processes** - Process monitoring with search capabilities
7. **Ports** - I/O port management and inspection
8. **Sockets** - TCP/UDP socket information and monitoring
9. **ETS** - In-memory table storage, search, and inspection
10. **Ecto Stats** - Database index usage and analytics

### Key Capabilities

- **Real-time metrics**: Telemetry event visualization with auto-refreshing charts
- **System monitoring**: CPU, memory, disk, process, and port monitoring
- **Request tracking**: Detailed per-request logging with durations
- **Database analytics**: Ecto index usage and performance insights
- **Distributed nodes**: Monitor and view metrics across connected Erlang nodes
- **Process inspection**: Search, inspect, and analyze running processes
- **Live updates**: All metrics update in real-time via WebSocket

## Configuration

### Required Configuration

Configure signing salt in your endpoint:

```elixir
config :phoenix_live_view, :signing_salt, "your_secret_salt"
```

### Optional Environment Guards

Restrict dashboard access to specific environments:

```elixir
if Mix.env() in [:dev, :test] do
  import Phoenix.LiveDashboard.Router

  scope "/dashboard" do
    pipe_through :browser
    live_dashboard "/"
  end
end
```

### Custom Metrics

Pass custom telemetry handler to dashboard:

```elixir
live_dashboard "/", metrics: MyAppWeb.Telemetry
```

Implement telemetry handler:

```elixir
defmodule MyAppWeb.Telemetry do
  def handle_event(_event, _measurements, _metadata, _config) do
    # Handle telemetry events
  end
end
```

### WebSocket Configuration for Production

For production deployments, configure WebSocket support in your web server:

**Nginx example:**

```nginx
location /dashboard/live {
  proxy_pass http://localhost:4000;
  proxy_http_version 1.1;
  proxy_set_header Upgrade $http_upgrade;
  proxy_set_header Connection "upgrade";
}
```

## Best Practices

### Security in Production

**CRITICAL**: Never expose dashboard publicly. Use one of two authentication approaches:

1. **Admin Authentication Pipeline** - Generate authentication resources and protect dashboard routes
2. **HTTP Basic Auth** - Use environment variables with basic auth middleware

Example with HTTP Basic Auth:

```elixir
defp basic_auth(conn, _opts) do
  username = System.get_env("DASHBOARD_USER")
  password = System.get_env("DASHBOARD_PASS")

  case Plug.BasicAuth.parse_credentials(conn) do
    {^username, ^password} -> conn
    _ -> Plug.BasicAuth.request_basic_auth(conn)
  end
end
```

### Monitoring Patterns

- **Metrics charts**: Add custom telemetry events and visualize in dashboard
- **Request analysis**: Use request logging to identify slow endpoints
- **Process inspection**: Search for stuck/idle processes affecting performance
- **ETS tables**: Monitor in-memory tables for memory leaks
- **Distributed debugging**: Connect to multiple nodes for cluster-wide visibility

### Performance Considerations

- Dashboard adds minimal overhead - safe for production with authentication
- Real-time updates use efficient WebSocket communication
- Metrics retained in memory - configure retention policies for long-running systems
- Disable modules you don't need to reduce memory usage

### Integration with Telemetry

Define telemetry events in your application:

```elixir
:telemetry.attach(
  "myapp_http_requests",
  [:myapp, :http, :request],
  &handle_http_request/4,
  nil
)
```

Metrics automatically visualized in dashboard Metrics module with configurable retention and refresh rates.

---

**Version:** 0.8.7
**Source:** [hexdocs.pm/phoenix_live_dashboard](https://hexdocs.pm/phoenix_live_dashboard/)
**Generated:** 2025-10-28
