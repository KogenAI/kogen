# phoenix_live_view

Phoenix LiveView is a library that provides server-rendered real-time user interfaces without requiring JavaScript development. LiveView enables you to build interactive, low-latency web applications using Elixir by managing stateful processes on the server that efficiently push DOM updates to connected clients. When a client first requests a LiveView, the server renders HTML; upon connection, the request upgrades to a persistent, stateful WebSocket connection that allows the server to push incremental DOM diffs in response to user interactions and server-side state changes.

The framework integrates deeply with Phoenix, providing form bindings, file upload handling, file stream management, and JavaScript interoperability through client hooks and command APIs. LiveView abstracts away boilerplate for common patterns like async operations, flash messages, and navigation while maintaining full control over lifecycle callbacks for both server-side and client-side interactions.

## Quick Start

**Installation** (Phoenix 1.7+):

```bash
mix phx.new my_app --live
```

**Basic LiveView Module**:

```elixir
defmodule MyAppWeb.Live.Counter do
  use Phoenix.LiveView

  def mount(_params, _session, socket) do
    {:ok, assign(socket, :count, 0)}
  end

  def render(assigns) do
    ~H"""
    <div>
      <p>Count: <%= @count %></p>
      <button phx-click="increment">Increment</button>
    </div>
    """
  end

  def handle_event("increment", _params, socket) do
    {:noreply, update(socket, :count, &(&1 + 1))}
  end
end
```

**Router Setup**:

```elixir
defmodule MyAppWeb.Router do
  use Phoenix.Router
  live "/counter", Live.Counter
end
```

## Documentation Sections

- [Lifecycle and Callbacks](phoenix_live_view-1.1.28-lifecycle.md)
- [Form Bindings and Input Handling](phoenix_live_view-1.1.28-forms.md)
- [File Uploads and Streaming](phoenix_live_view-1.1.28-uploads.md)
- [JavaScript Interoperability](phoenix_live_view-1.1.28-js-interop.md)
- [LiveComponents and Composition](phoenix_live_view-1.1.28-components.md)
- [Async Operations and Background Tasks](phoenix_live_view-1.1.28-async.md)
- [Navigation and Routing](phoenix_live_view-1.1.28-navigation.md)

---

**Version:** 1.1.28
**Source:** [hexdocs.pm/phoenix_live_view](https://hexdocs.pm/phoenix_live_view/)
**Generated:** 2026-04-25
