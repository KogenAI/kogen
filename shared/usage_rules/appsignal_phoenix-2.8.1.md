# appsignal_phoenix

AppSignal Phoenix provides comprehensive performance monitoring and error tracking for Phoenix web applications. It automatically instruments HTTP requests and can be extended to monitor channels, LiveView, and custom code paths.

## Quick Start

### Installation

Add to `mix.exs` dependencies:

```elixir
{:appsignal_phoenix, "~> 2.8"}
```

Run:

```bash
mix deps.get
mix appsignal.install YOUR_PUSH_API_KEY
```

### Basic Setup

Add to your endpoint module (`lib/your_app_web/endpoint.ex`):

```elixir
defmodule YourAppWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :your_app
  use Appsignal.Phoenix

  # ... rest of configuration
end
```

This automatically instruments all HTTP requests without additional setup.

## Core Concepts

### Automatic Instrumentation

- **HTTP Requests**: All requests automatically tracked with performance metrics and error reporting
- **Namespace Isolation**: Requests are organized by namespace (e.g., `http_request`)
- **Error Capture**: Unhandled exceptions automatically reported with stack traces

### Channels Support

Wrap channel message handlers with `Appsignal.Phoenix.Channel.instrument/5` to track incoming channel requests:

```elixir
Appsignal.Phoenix.Channel.instrument(socket, "user:123", "message", fn ->
  # channel logic
end)
```

Or use decorators (less overhead):

```elixir
@decorate channel_action()
def handle_in("message", payload, socket) do
  # handler code
end
```

### LiveView Support

Two approaches available:

**Automatic Telemetry (Recommended, v2.1.0+)**:
Call in your application startup:

```elixir
Appsignal.Phoenix.LiveView.attach()
```

This automatically instruments all `mount`, `handle_event`, and `handle_param` events under the `live_view` namespace.

**Manual Instrumentation**:
Use helper functions for fine-grained control of specific LiveView lifecycle events.

### Plugs and Middleware

Supports custom instrumentation through Plug-based middleware for complex workflows and custom request handlers.

## Configuration

### Environment Variables

Configuration is managed via the core AppSignal package and environment variables set during `mix appsignal.install`. Key settings:

- **Push API Key**: Set during installation
- **App Name**: Automatically detected from your app name
- **Environment**: Automatically detected (dev, prod, etc.)

### Custom Instrumentation

Leverage the [Elixir instrumentation documentation](https://docs.appsignal.com/elixir/instrumentation.html) for deeper insights into custom performance tracking and error handling patterns.

## Best Practices

1. **Use Automatic Telemetry**: For LiveView apps using v2.1.0+, prefer `Appsignal.Phoenix.LiveView.attach()` over manual instrumentation to reduce overhead.

2. **Channel Instrumentation**: Always wrap channel handlers for visibility into real-time communication performance.

3. **Error Context**: AppSignal automatically captures errors; focus on adding custom instrumentation for business-critical flows.

4. **View Layer**: For view-specific instrumentation, use `Appsignal.Phoenix.View` in your view functions (after `use Phoenix.View`).

5. **Performance Monitoring**: Use automatic instrumentation as a baseline; add custom instrumentation only for flows that need deeper visibility.

6. **Namespace Organization**: Leverage request namespaces to group related monitoring data for easier analysis.

---

**Version:** 2.8.1  
**Source:** [hexdocs.pm/appsignal_phoenix](https://hexdocs.pm/appsignal_phoenix/)  
**Integration Guide:** [docs.appsignal.com/elixir/integrations/phoenix](https://docs.appsignal.com/elixir/integrations/phoenix.html)  
**Generated:** 2026-04-25
