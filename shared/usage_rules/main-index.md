# phoenix_live_view

Phoenix LiveView is a powerful framework for building interactive, real-time web applications using server-rendered HTML and WebSocket connections. It eliminates the need for extensive JavaScript by keeping application state on the server and automatically pushing minimal diffs to the client when state changes. LiveViews are processes that receive events, update their state, and render updates to a page as diffs—combining the best of server-side logic with responsive client-side experiences.

The framework's key strength is its dual-phase architecture: initial page load renders as standard HTTP for fast performance and SEO, then upgrades to a persistent WebSocket connection for real-time updates. Developers write pure Elixir using callbacks like `mount/3`, `render/1`, and `handle_event/3`, without requiring extensive knowledge of JavaScript or frontend frameworks.

LiveView's change-tracking system is intelligent—it knows exactly which parts of templates changed and transmits only those diffs, making applications highly efficient. The framework ships by default in new Phoenix applications and provides battle-tested patterns for forms, uploads, navigation, and real-time features.

## Quick Start

1. **Define a LiveView module** with required callbacks:

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
      <p>Count: {@count}</p>
      <button phx-click="increment">Increment</button>
    </div>
    """
  end
end
```

2. **Add route in router**:

```elixir
scope "/", MyAppWeb do
  live "/counter", CounterLive
end
```

3. **Ensure LiveView assets are loaded** in your app layout (JS/CSS hooks).

## Documentation Sections

- [Core Concepts & Lifecycle](phoenix_live_view-1.1.32-lifecycle.md) — Understanding mount, render, handle_event, and handle_params
- [State Management & Assigns](phoenix_live_view-1.1.32-assigns.md) — Working with assigns, change tracking, and anti-patterns
- [Event Bindings & Client Interaction](phoenix_live_view-1.1.32-bindings.md) — phx-click, phx-change, debounce, throttle, and more
- [Form Handling](phoenix_live_view-1.1.32-forms.md) — Form validation, error display, special inputs, and file uploads
- [Navigation & Routing](phoenix_live_view-1.1.32-navigation.md) — Live navigation, push_patch vs push_navigate, live_session
- [Uploads & File Handling](phoenix_live_view-1.1.32-uploads.md) — File uploads, progress tracking, cloud uploads, and storage strategies
- [JavaScript Interoperability](phoenix_live_view-1.1.32-js-interop.md) — Hooks, JS commands, client-side events, and server-pushed messages
- [Security & Best Practices](phoenix_live_view-1.1.32-security.md) — Authentication, authorization, deployment, and common pitfalls

---

**Version:** 1.1.32
**Source:** https://github.com/phoenixframework/phoenix_live_view/tree/v1.1.32
**Generated:** 2026-06-17
