# phoenix - LiveView & Reactive UIs

## Core Concept

Phoenix LiveView is a framework feature for building interactive, real-time user interfaces while maintaining server-side state. LiveViews are processes that receive events, update their state, and render updates to a page as diffs. This approach eliminates the need for extensive client-side JavaScript frameworks by keeping application logic on the server.

The initial page load follows Phoenix's standard HTTP request cycle, delivering an HTML response. A WebSocket connection then establishes for ongoing communication. When state changes occur, only the modified HTML portions are transmitted to the browser—a "diffs over the wire" model. This provides the responsiveness of single-page applications with the simplicity of server-rendered code.

## How It Works

LiveView maintains a persistent process that handles user events through a bidirectional connection. Unlike stateless controllers requiring separate requests for each interaction, state updates automatically trigger efficient re-renders without full page reloads. The client receives only the changes, dramatically reducing bandwidth and improving perceived performance.

## Essential Components

**mount/3** initializes state and socket when the LiveView starts:

```elixir
def mount(_params, _session, socket) do
  {:ok, assign(socket, :counter, 0)}
end
```

**render/1** defines the display template using HEEx syntax (HTML + Elixir expressions):

```elixir
def render(assigns) do
  ~H"""
  <div>
    <p>Counter: <%= @counter %></p>
    <button phx-click="increment">+</button>
  </div>
  """
end
```

**handle_event/3** processes client interactions like button clicks:

```elixir
def handle_event("increment", _value, socket) do
  {:noreply, update(socket, :counter, &(&1 + 1))}
end
```

**handle_info/2** manages process messages from PubSub and other sources:

```elixir
def handle_info({:new_message, msg}, socket) do
  {:noreply, assign(socket, :messages, [msg | socket.assigns.messages])}
end
```

## Template Syntax

LiveView templates use HEEx (HTML + Elixir Extended), which provides:

**Interpolation:**

```elixir
<p>Counter: <%= @counter %></p>
```

**Conditionals:**

```elixir
<%= if @logged_in do %>
  <p>Welcome <%= @username %></p>
<% end %>
```

**Lists:**

```elixir
<ul>
  <%= for post <- @posts do %>
    <li><%= post.title %></li>
  <% end %>
</ul>
```

**Event Bindings:**

```elixir
<button phx-click="increment">+</button>
<input type="text" phx-change="filter" />
<form phx-submit="save">...</form>
```

## Event Handling

Events flow from the client to the server through WebSocket. The `phx-` attributes capture user interactions:

- `phx-click="event"` - button clicks
- `phx-change="event"` - input changes (debounced)
- `phx-submit="event"` - form submissions
- `phx-focus="event"` - input focus
- `phx-blur="event"` - input blur

Handle events in the LiveView:

```elixir
def handle_event("filter", %{"query" => query}, socket) do
  filtered = filter_posts(query)
  {:noreply, assign(socket, :posts, filtered)}
end
```

## State Management

Update socket state using `assign/3`:

```elixir
assign(socket, :key, value)
```

Update nested state with `update/3`:

```elixir
update(socket, :user, fn user -> %{user | name: "New Name"} end)
```

Chain assignments:

```elixir
socket
|> assign(:posts, posts)
|> assign(:total, length(posts))
|> assign(:page, 1)
```

## Lifecycle

**mount/3** runs once when the LiveView first connects. Return `{:ok, socket}` to render:

```elixir
def mount(_params, _session, socket) do
  {:ok, assign(socket, :users, list_users())}
end
```

On live navigation (client-side), `mount/3` runs again but only for new LiveViews, not the current one.

**handle_params/3** (optional) updates when URL parameters change:

```elixir
def handle_params(%{"id" => id}, _uri, socket) do
  {:noreply, assign(socket, :post, get_post(id))}
end
```

## Communication with Other Processes

Subscribe to PubSub from `mount/3`:

```elixir
def mount(_params, _session, socket) do
  Phoenix.PubSub.subscribe(MyApp.PubSub, "posts")
  {:ok, socket}
end
```

Handle broadcast messages in `handle_info/2`:

```elixir
def handle_info({:new_post, post}, socket) do
  new_posts = [post | socket.assigns.posts]
  {:noreply, assign(socket, :posts, new_posts)}
end
```

## Code Generation

Phoenix provides code generators for complete CRUD implementations:

```bash
mix phx.gen.live Blog Post posts title:string body:text
```

This generates:

- A LiveView component with mount, render, and event handlers
- Database schema and migration
- A supervisor for spawning LiveView processes
- Full CRUD functionality comparable to HTML generators

## Performance Considerations

- LiveView maintains a process per connected client
- Use `phx-debounce` on inputs to reduce handle_event calls
- Use `phx-throttle` for frequent events
- Filter PubSub messages in `handle_info/2` to avoid unnecessary renders
- Use `handle_async/3` for long-running operations without blocking the UI

## Best Practices

- **Keep state simple**: Store only what's needed for rendering
- **Use components**: Extract reusable UI into LiveComponent modules
- **Test with ExUnit**: LiveView provides testing utilities via `Phoenix.LiveViewTest`
- **Handle errors**: Use error assigns to provide user feedback
- **Subscribe carefully**: Unsubscribe when leaving a LiveView to prevent memory leaks

---

[← Back to main](phoenix-1.8.9.md)
**Version:** 1.8.9
