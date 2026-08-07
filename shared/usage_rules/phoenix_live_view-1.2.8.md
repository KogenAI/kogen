# phoenix_live_view

Phoenix LiveView is a framework for building interactive, real-time web interfaces with Elixir. It enables you to create dynamic, stateful pages that respond to user actions without writing complex JavaScript. A LiveView is a process that receives events, updates its state, and renders updates to a page as diffs, maintaining server-side state through socket assigns.

The framework operates through a dual-phase lifecycle: initially functioning as a standard HTTP request with HTML response, then upgrading to a stateful process once the client connects. This ensures functional pages even without JavaScript enabled. LiveView uses sophisticated asynchronous handling through `assign_async/3` and `start_async/3` for background tasks, and provides collection management through streams for large datasets.

LiveView guarantees functional pages while offering real-time reactivity through WebSocket connections. It prioritizes security by treating all client parameters as untrusted data requiring authorization and validation. The framework provides built-in support for file uploads with progress tracking, form bindings with real-time validation, and JavaScript interoperability through hooks and bidirectional messaging.

## Quick Start

**Installation:**

```bash
mix phx.new my_app --live
```

**Basic LiveView:**

```elixir
defmodule MyAppWeb.CounterLive do
  use Phoenix.LiveView

  def mount(_params, _session, socket) do
    {:ok, assign(socket, :count, 0)}
  end

  def render(assigns) do
    ~H"""
    <div>
      <p><%= @count %></p>
      <button phx-click="inc">+</button>
    </div>
    """
  end

  def handle_event("inc", _params, socket) do
    {:noreply, assign(socket, :count, socket.assigns.count + 1)}
  end
end
```

## Documentation Sections

- [Core Lifecycle & State](phoenix_live_view-1.2.8-lifecycle.md)
- [Form Bindings & Validation](phoenix_live_view-1.2.8-forms.md)
- [DOM Bindings & Interactions](phoenix_live_view-1.2.8-bindings.md)
- [File Uploads](phoenix_live_view-1.2.8-uploads.md)
- [JavaScript Interoperability](phoenix_live_view-1.2.8-js-interop.md)
- [Security Best Practices](phoenix_live_view-1.2.8-security.md)

---

**Version:** 1.2.8
**Source:** [phoenix-live-view.hexdocs.pm](https://phoenix-live-view.hexdocs.pm/1.2.8)
**Generated:** 2026-08-07
