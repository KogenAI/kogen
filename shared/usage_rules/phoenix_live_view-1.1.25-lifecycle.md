# phoenix_live_view - Lifecycle & Rendering

## Mount Callback

`mount/3` is the entry point invoked when a LiveView initializes. It receives params (from URL), session data, and an empty socket. Use mount to load initial data and configure the socket.

```elixir
@impl true
def mount(params, session, socket) do
  user_id = session["user_id"]

  if connected?(socket) do
    # Subscriptions only after initial render
    Phoenix.PubSub.subscribe(MyApp.PubSub, "users:#{user_id}")
  end

  {:ok, assign(socket, user_id: user_id, data: load_data(user_id))}
end
```

The `:ok` return tuple keeps the LiveView open. Return `{:ok, socket, temporary_assigns: [...]}` to reset listed assigns after every render, useful for memory-heavy objects.

The `connected?/1` guard distinguishes initial render (false, HTML rendered server-side) from live connections (true, WebSocket or long-polling). Use this to defer subscriptions and expensive operations.

## Handle Params Callback

`handle_params/3` fires after mount and whenever URL parameters change. Use it to sync page state with the URL.

```elixir
@impl true
def handle_params(%{"id" => id}, _uri, socket) do
  item = load_item(id)
  {:noreply, assign(socket, :item, item)}
end
```

Return `:noreply` to skip re-rendering (render/1 is called automatically). The third parameter is the full URI for logging or client-side routing context.

## Render Callback

`render/1` generates HTML. Use HEEx templates (`.heex` syntax inside function or file-based `.html.heex`):

```elixir
@impl true
def render(assigns) do
  ~H"""
  <div>
    <h1><%= @page_title %></h1>
    <ul>
      <li :for={item <- @items}>
        <%= item.name %>
        <button phx-click="delete" phx-value-id={item.id}>Delete</button>
      </li>
    </ul>
  </div>
  """
end
```

Use `<.function_name param={value} />` to render components. Assigns are automatically available in templates as `@variable`.

## Lifecycle Order

1. `mount/3` runs once, initializing socket with data
2. `render/1` generates HTML
3. Client receives page and connects WebSocket
4. `handle_params/3` runs after connection
5. `render/1` runs again (triggers diff to client)
6. `handle_event/3` responds to client interactions
7. `terminate/2` runs on disconnect

## Assigns & State Management

Socket assigns hold server state, automatically diffed to client:

```elixir
socket = assign(socket, :count, 10)  # Single assign
socket = assign(socket, count: 10, name: "Item")  # Multiple assigns
socket = update(socket, :count, &(&1 + 1))  # Update function
```

Large, memory-intensive assigns should use `temporary_assigns` to reset after render:

```elixir
def mount(_params, _session, socket) do
  {:ok, socket, temporary_assigns: [large_data: nil]}
end

def handle_event("load", _value, socket) do
  {:noreply, assign(socket, large_data: load_expensive_data())}
  # After render, large_data is reset to nil
end
```

## Template Collocation

File-based templates using `.html.heex` automatically pair with LiveView modules:

```
lib/my_app_web/live/
  counter_live.ex
  counter_live.html.heex
```

The template file automatically becomes the `render/1` callback. Define `render/1` in the module only when using inline HEEx or custom logic.

## Render Only on Change

LiveView only re-renders when assigns change. Optimized updates use `send_update/3` or patches to avoid full re-renders:

```elixir
# Update only a specific component
send_update(MyComponent, id: "comp-1", count: 5)
```

Use `:target` in event handlers to send updates to specific components without full LiveView render.

---

[← Back to main](phoenix_live_view-1.1.25.md)
**Version:** 1.1.25
