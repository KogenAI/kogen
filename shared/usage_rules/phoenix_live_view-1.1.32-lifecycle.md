# phoenix_live_view - Core Lifecycle & Callbacks

## LiveView Lifecycle Overview

A LiveView is a stateful process that receives events, updates its state, and renders updates to the page as HTML diffs. The lifecycle follows a distinct pattern:

**Initial HTTP Response:** When a user navigates to a LiveView route, Phoenix serves a traditional HTTP response rendering the initial page.

**WebSocket Connection:** Once the page loads, JavaScript establishes a persistent WebSocket connection, upgrading the request to a stateful process.

**Sequence:** `mount/3` → `handle_params/3` → `render/1` → event handlers → re-render

## Essential Callbacks

### mount/3

The entry point invoked during both initial render and client connection.

```elixir
def mount(params, session, socket) do
  {:ok, assign(socket, user_id: session["user_id"])}
end
```

**Parameters:**

- `params` - URL path parameters (when routed with `:id` segments)
- `session` - Session data passed from controller or live_session
- `socket` - The LiveView socket containing assigns

**Returns:**

- `{:ok, socket}` - Allows the LiveView to proceed
- `{:ok, socket, :temporary_assigns}` - Clears assigns after render
- `:error` - Rejects connection for unauthorized access

**Key Points:**

- Invoked once per LiveView lifecycle
- Must not be async; use `mount/1` in components for async operations
- All data loading should occur here, not in `handle_params/3`
- Cannot call `push_patch/2` or `push_navigate/2`

### handle_params/3

Processes URL parameters and query strings.

```elixir
def handle_params(%{"id" => id}, _uri, socket) do
  {:noreply, assign(socket, post_id: id)}
end
```

**Invocation:** Called after `mount/3` initially, then whenever patching occurs via `push_patch/2` or `link patch={...}`.

**Key Points:**

- Only update state for parameters expected to change via patching
- Validate parameters before using them
- Do not load data here; data should be loaded in `mount/3`
- Available on routed LiveViews only

### render/1

Generates the HTML template output using HEEx syntax.

```elixir
def render(assigns) do
  ~H"""
  <div class="container">
    <h1>{@title}</h1>
    <p>{@message}</p>
  </div>
  """
end
```

**Key Points:**

- Must return a template or iolist
- Has access to all assigns via the `@` sigil
- Re-rendered after every state change
- Supports composition with function components and live components

### handle_event/3

Responds to user interactions from the client.

```elixir
def handle_event("click", %{"id" => id}, socket) do
  {:noreply, assign(socket, selected: id)}
end
```

**Common Events:**

- `phx-click` - Button or link click
- `phx-submit` - Form submission
- `phx-change` - Form input change
- `phx-blur` - Input blur
- `phx-focus` - Input focus
- `phx-hook` - Custom JavaScript hook events

**Returns:**

- `{:noreply, socket}` - Update socket and re-render
- `{:reply, reply_map, socket}` - Send data back to client
- `{:noreply, socket}` with special assigns for async handling

### handle_info/2

Processes inter-process messages and PubSub events.

```elixir
def handle_info({:updated, data}, socket) do
  {:noreply, assign(socket, data: data)}
end
```

**Common Use Cases:**

- Broadcasting updates via Phoenix.PubSub
- Responding to GenServer messages
- Timer events from `Process.send_after/3`

```elixir
# Subscribe in mount
Phoenix.PubSub.subscribe(MyApp.PubSub, "room:#{room_id}")

# Receive in handle_info
def handle_info({:new_message, msg}, socket) do
  {:noreply, assign(socket, messages: [msg | socket.assigns.messages])}
end
```

### handle_async/3

Processes results from asynchronous operations started with `start_async/3`.

```elixir
def handle_async(:data_load, {:ok, result}, socket) do
  {:noreply, assign(socket, data: result)}
end

def handle_async(:data_load, {:exit, reason}, socket) do
  {:noreply, assign(socket, error: "Failed to load")}
end
```

**Returns:**

- `{:noreply, socket}` - Update socket with result
- `:error` - Re-run the async operation
- Any value to keep trying

## Socket Assigns

Assigns store server-side state accessible in templates via `@name` syntax.

```elixir
socket = assign(socket, count: 0)
socket = assign(socket, count: 1, name: "John")
socket = assign_new(socket, :default, fn -> 0 end)
```

**Key Points:**

- Changes trigger re-render automatically
- Assigns are not sent to clients (security)
- Use `assign_new/3` to set defaults only if unset
- Temporary assigns can be cleared after render with `:temporary_assigns` option

## Best Practices

**Separate Concerns:** Keep business logic in context modules; LiveViews should focus on state management and rendering.

**Minimize Re-renders:** Only update assigns that changed; use `:temporary_assigns` for large data that shouldn't persist.

**Use PubSub for Broadcasts:** When multiple users need updates, use `Phoenix.PubSub` rather than polling.

**Validate in mount/3:** Authorization checks should occur in `mount/3`, not just in plugs, since navigation bypasses the plug pipeline.

---

[← Back to main](phoenix_live_view-1.1.32.md)  
**Version:** 1.1.32
