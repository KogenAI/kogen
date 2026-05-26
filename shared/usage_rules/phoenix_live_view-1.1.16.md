# phoenix_live_view

Phoenix LiveView is a real-time web framework that enables building interactive user interfaces using Elixir. It combines server-side logic with client-side reactivity by establishing stateful WebSocket connections while maintaining HTML rendering as a fallback. LiveView handles state management, event processing, and DOM updates through a process-based architecture, allowing developers to write full-stack applications without traditional JavaScript complexity.

The framework provides a comprehensive set of bindings for form handling, file uploads, navigation, and JavaScript interoperability. LiveView automatically manages DOM diffing to send only minimal updates to the client, making it efficient for real-time applications including live search, collaborative editing, dashboards, and streaming data applications.

LiveView is built on Phoenix and integrates with Elixir's supervisor trees, message passing, and pattern matching to create responsive applications that scale from single-user interactions to multi-user real-time collaboration.

## Quick Start

**Installation in Phoenix project:**

```elixir
# mix.exs dependencies
def deps do
  [
    {:phoenix_live_view, "~> 1.1.16"}
  ]
end
```

**Basic LiveView module:**

```elixir
defmodule MyAppWeb.CounterLive do
  use Phoenix.LiveView

  def mount(_params, _session, socket) do
    {:ok, assign(socket, :count, 0)}
  end

  def handle_event("increment", _params, socket) do
    {:noreply, update(socket, :count, &(&1 + 1))}
  end

  def render(assigns) do
    ~H"""
    <div>
      <button phx-click="increment">Count: <%= @count %></button>
    </div>
    """
  end
end
```

**Route definition:**

```elixir
defmodule MyAppWeb.Router do
  use Phoenix.Router

  scope "/" do
    live "/counter", CounterLive
  end
end
```

## Documentation Sections

- [Lifecycle and State Management](phoenix_live_view-1.1.16-lifecycle.md)
- [Form Handling and Data Binding](phoenix_live_view-1.1.16-forms.md)
- [Navigation and Routing](phoenix_live_view-1.1.16-navigation.md)
- [Event Bindings and Interactions](phoenix_live_view-1.1.16-bindings.md)
- [File Uploads and Streams](phoenix_live_view-1.1.16-uploads.md)
- [JavaScript Interoperability](phoenix_live_view-1.1.16-js-interop.md)
- [Telemetry and Performance Monitoring](phoenix_live_view-1.1.16-telemetry.md)

---

**Version:** 1.1.16
**Source:** [hexdocs.pm/phoenix_live_view](https://hexdocs.pm/phoenix_live_view/)
**Generated:** 2025-10-28
