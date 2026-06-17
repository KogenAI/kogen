# phoenix_live_view - Core Concepts & Lifecycle

## Architecture Overview

A LiveView is a stateful Elixir process that manages a user's session and renders HTML via WebSocket. The dual-phase lifecycle ensures optimal performance:

1. **HTTP Phase (Initial Request)**: Browser requests a URL, which renders as static HTML via standard HTTP. This ensures fast First Meaningful Paint and works even with JavaScript disabled.

2. **WebSocket Phase (Connected State)**: Once the page loads, JavaScript establishes a WebSocket connection. The browser sends a security token, the server spawns a new LiveView process, and bidirectional communication begins.

When using `push_patch/2`, only the current LiveView updates. When using `push_navigate/2`, the current LiveView unmounts and a new one mounts—similar to navigation between different routes.

## Essential Callbacks

### mount/3

Entry point invoked during initial HTTP request and after WebSocket connection establishes.

```elixir
def mount(params, session, socket) do
  {:ok, socket}
  # OR with error
  {:error, {:redirect, to: "/"}}
end
```

- **params**: URL parameters (e.g., from `/users/:id`)
- **session**: Session data (authenticated user, etc.)
- **socket**: State container where assigns are stored

Called twice: once during HTTP render, once during connection. Use `connected?(socket)` to differentiate if needed.

### render/1

Generates HTML using HEEx template syntax. Called automatically after mount or when assigns change.

```elixir
def render(assigns) do
  ~H"""
  <div>
    <h1>{@user.name}</h1>
    <button phx-click="delete">Delete</button>
  </div>
  """
end
```

Returns HEEx template with automatic change tracking. Only changed sections transmit over the wire.

### handle_params/3

Processes URL and query parameters after mount, fires on every `push_patch/2` navigation.

```elixir
def handle_params(params, url, socket) do
  {:noreply, socket}
end
```

**Key pattern**: Load initial data in `mount/3`, handle parameter changes in `handle_params/3`. For example, load a blog post's ID in mount but handle comment pagination in handle_params.

### handle_event/3

Responds to all user interactions from the client (button clicks, form submissions, etc.).

```elixir
def handle_event("delete", _params, socket) do
  {:noreply, socket}  # Renders updated template
  # OR redirect
  {:noreply, push_navigate(socket, to: "/")}
  # OR return error tuple
  {:error, "Not permitted"}
end
```

Always verify permissions server-side in every event handler.

### handle_info/2

Processes messages from other Elixir processes (pub/sub, timers, tasks).

```elixir
def handle_info({:user_updated, user}, socket) do
  {:noreply, assign(socket, :user, user)}
end
```

Used for broadcasting changes, async operations, and process communication.

## Lifecycle Order

1. **HTTP Mount**: `mount/3` called with `connected?: false`
2. **Render**: `render/1` called, HTML sent to browser
3. **WebSocket Mount**: `mount/3` called again with `connected?: true`
4. **handle_params/3**: Called before first render on connected mount
5. **Event Handling**: Subsequent `handle_event/3`, `handle_info/2` calls as user interacts

## Key Utilities

**assign/2-3**: Update socket state

```elixir
assign(socket, :user, user)
assign(socket, user: user, admin: true)
```

**update/3**: Modify existing assign

```elixir
update(socket, :counter, &(&1 + 1))
```

**assign_new/3**: Assign only if not already set (useful in shared layouts)

```elixir
assign_new(socket, :current_user, fn -> get_current_user() end)
```

**connected?/1**: Check if WebSocket is active

```elixir
if connected?(socket), do: subscribe_to_updates()
```

## Common Patterns

**Loading async data on connect**:

```elixir
def mount(_params, _session, socket) do
  if connected?(socket) do
    {:ok, assign(socket, :data, fetch_data())}
  else
    {:ok, assign(socket, :data, nil)}
  end
end
```

**Form submission with validation**:

```elixir
def handle_event("save", params, socket) do
  case MyContext.create_item(params) do
    {:ok, item} -> {:noreply, assign(socket, :item, item)}
    {:error, changeset} -> {:noreply, assign(socket, :changeset, changeset)}
  end
end
```

**Showing/hiding based on connected state**:

```heex
<%= if connected?(@socket) do %>
  <div>Live features available</div>
<% end %>
```

## Error Handling

Exceptions during HTTP mount convert to error pages (like normal controllers). Exceptions during connected mount crash the LiveView process; the client reconnects and remounts via HTTP. This recovery mechanism often automatically fixes transient issues.

For expected errors (validation failures), use assigns to track state and render appropriate messages—don't raise exceptions.

---

[← Back to main](main-index.md)
**Version:** 1.1.32
