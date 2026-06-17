# phoenix_live_view

Phoenix LiveView is a powerful framework for building interactive, real-time web applications in Elixir without requiring complex client-side JavaScript. It enables developers to create stateful, responsive UIs by leveraging WebSocket connections that stream incremental HTML diffs to the browser. LiveView processes run on the server, maintain state via socket assigns, and communicate with clients through well-defined event handlers and callbacks.

Version 1.1.32 introduces improved async operations, stream management for large collections, and enhanced component patterns. LiveView seamlessly integrates with Phoenix, supporting both functional components (stateless) and live components (stateful), with comprehensive support for forms, file uploads, and navigation without full page reloads.

## Quick Start

```elixir
# Add to mix.exs
{:phoenix_live_view, "~> 1.1.32"}

# Generate a LiveView in your Phoenix app
mix phx.gen.live_view MyLiveView

# Define in your router
live_session :default do
  live "/", MyLiveView
end

# Basic LiveView structure
defmodule MyLiveView do
  use Phoenix.LiveView

  def mount(_params, _session, socket) do
    {:ok, assign(socket, count: 0)}
  end

  def handle_event("increment", _params, socket) do
    {:noreply, update(socket, :count, &(&1 + 1))}
  end

  def render(assigns) do
    ~H"""
    <button phx-click="increment">
      Count: {@count}
    </button>
    """
  end
end
```

## Documentation Sections

- [Core Lifecycle & Callbacks](phoenix_live_view-1.1.32-lifecycle.md)
- [Components & Reusability](phoenix_live_view-1.1.32-components.md)
- [Forms & User Input](phoenix_live_view-1.1.32-forms.md)
- [Navigation & URL Handling](phoenix_live_view-1.1.32-navigation.md)
- [Asynchronous Operations & Streams](phoenix_live_view-1.1.32-async.md)
- [File Uploads & Media](phoenix_live_view-1.1.32-uploads.md)
- [Client Interop & JavaScript](phoenix_live_view-1.1.32-js.md)
- [Router Integration & Sessions](phoenix_live_view-1.1.32-router.md)

---

**Version:** 1.1.32  
**Source:** https://hexdocs.pm/phoenix_live_view/1.1.32  
**Generated:** 2026-06-17
