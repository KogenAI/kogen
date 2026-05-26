# phoenix_live_view

Phoenix LiveView is a framework for building interactive, real-time web interfaces without writing JavaScript. Each LiveView is a server-side process that receives client events, updates its state, and streams page diffs to the browser. This enables fully interactive applications with automatic synchronization between server and client, progressive rendering, and built-in support for forms, file uploads, and dynamic content updates.

LiveView handles the full lifecycle from initial mount through user interactions to disconnection. It manages socket assigns as the source of truth for page state, provides efficient DOM diffing to minimize bandwidth, and includes first-class support for asynchronous operations, file uploads, and large collections via streams.

## Quick Start

```elixir
# lib/my_app_web/live/counter_live.ex
defmodule MyAppWeb.CounterLive do
  use Phoenix.LiveView

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :count, 0)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <p>Count: <%= @count %></p>
      <button phx-click="inc">+</button>
    </div>
    """
  end

  @impl true
  def handle_event("inc", _value, socket) do
    {:noreply, update(socket, :count, &(&1 + 1))}
  end
end
```

Add to your router: `live "/counter", CounterLive`

## Documentation Sections

- [Lifecycle & Rendering](phoenix_live_view-1.1.25-lifecycle.md)
- [Form Bindings & Validation](phoenix_live_view-1.1.25-forms.md)
- [Event Bindings & Interactions](phoenix_live_view-1.1.25-bindings.md)
- [Async Operations](phoenix_live_view-1.1.25-async.md)
- [Streams & Large Collections](phoenix_live_view-1.1.25-streams.md)
- [File Uploads](phoenix_live_view-1.1.25-uploads.md)
- [Navigation & Routing](phoenix_live_view-1.1.25-navigation.md)

---

**Version:** 1.1.25
**Source:** [hexdocs.pm/phoenix_live_view](https://hexdocs.pm/phoenix_live_view/)
**Generated:** 2026-04-25
