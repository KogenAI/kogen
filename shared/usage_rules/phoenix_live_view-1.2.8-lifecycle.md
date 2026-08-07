# phoenix_live_view - Core Lifecycle & State

## LiveView Lifecycle Overview

A LiveView is a process that receives events, updates state, and renders updates as diffs. The lifecycle follows a two-phase pattern:

1. **Initial HTTP Request Phase**: A stateless request/response cycle that renders initial HTML
2. **Client Connection Phase**: Upgrades to a stateful process for ongoing communication via WebSocket

## Lifecycle Callbacks Sequence

Phoenix LiveView invokes callbacks in this precise order:

### 1. Mount (mount/3)

The entry point for every LiveView. Receives params, session, and socket:

```elixir
def mount(params, session, socket) do
  {:ok, assign(socket, :user_id, params["user_id"])}
end
```

- **Called**: On initial page load (HTTP) and client connection
- **params**: URL parameters (requires authorization and validation)
- **session**: Server-side session data (trusted)
- **socket**: Connection state container

### 2. Handle Params (handle_params/3)

Processes URI and query parameters after mount:

```elixir
def handle_params(params, _uri, socket) do
  {:noreply, assign(socket, :page, params["page"])}
end
```

- **Called**: After mount, on navigation
- **URI**: Full URI for routing context
- **Use case**: Dynamic routing, page filtering, URL state sync

### 3. Render (render/1)

Generates HTML output from assigned state:

```elixir
def render(assigns) do
  ~H"""
  <div><%= @message %></div>
  """
end
```

## Server-Side State Management

### Assigns (Socket Assigns)

All reactive state lives in socket assigns. Use `assign/2` or `assign/3`:

```elixir
socket
|> assign(:count, 0)
|> assign(user: user, admin?: user.admin)
```

Assigns are:

- **Rendered automatically** in templates when referenced (`@count`, `@user`)
- **Diffed on client**: only changed values sent to browser
- **Reactive**: updating an assign triggers re-render

### Async Operations (assign_async/3)

Load data without blocking renders:

```elixir
def mount(params, session, socket) do
  {:ok,
    socket
    |> assign_async(:posts, fn -> {:ok, %{posts: load_posts()}} end)
  }
end

def render(assigns) do
  ~H"""
  <.async_result assign={@posts}>
    <:loading>Loading...</:loading>
    <:failed :let={{_kind, reason}}>Error: <%= reason %></:failed>
    <:ready :let={{%{posts: posts}}}><%= posts %></:ready>
  </.async_result>
  """
end
```

- **Non-blocking**: Page renders while data loads
- **Automatic status**: `loading`, `ready`, or `failed` states
- **Ideal for**: Database queries, external API calls

### Start Async (start_async/3)

Launch background tasks after render:

```elixir
def mount(_params, _session, socket) do
  {:ok, start_async(socket, :email, fn -> send_email() end)}
end

def handle_async(:email, {:ok, result}, socket) do
  {:noreply, assign(socket, :email_sent, true)}
end
```

## Event Handlers

### Handle Event (handle_event/3)

Process user interactions from the client:

```elixir
def handle_event("click", _params, socket) do
  {:noreply, assign(socket, :clicked, true)}
end

def handle_event("submit", %{"form" => form_data}, socket) do
  case save_data(form_data) do
    {:ok, record} -> {:noreply, assign(socket, :data, record)}
    {:error, reason} -> {:noreply, assign(socket, :error, reason)}
  end
end
```

- **First argument**: Event name from `phx-click`, `phx-change`, etc.
- **Second argument**: Event payload (form params, phx-value attributes)
- **Return**: `{:noreply, socket}` updates state, `{:reply, payload, socket}` sends reply to client

### Handle Info (handle_info/2)

Receive messages from other processes:

```elixir
def handle_info({:message, content}, socket) do
  {:noreply, assign(socket, :message, content)}
end
```

Common sources:

- Other LiveViews via `send/2`
- PubSub broadcasts
- Async task completion

## Important Security Note

**The params argument contains untrusted data from the client. You must authorize and validate this data before using it to fetch or modify resources.**

Always verify user permissions and validate inputs in mount/3 and handle_params/3 before accessing sensitive data or performing mutations.

---

[← Back to main](phoenix_live_view-1.2.8.md)
**Version:** 1.2.8
