# phoenix_live_view - Lifecycle and Callbacks

## Core Lifecycle Model

A LiveView is a process that receives events, updates its state, and renders updates to a page as diffs. The lifecycle begins as a standard HTTP request. Upon client connection (usually after initial render), the connection upgrades to a stateful WebSocket, allowing the server to maintain process state and push incremental updates.

### Mount Phase

`mount/3` is the primary entry point, called during both initial HTTP request and when the client connects over WebSocket:

```elixir
def mount(params, session, socket) do
  {:ok, assign(socket, :counter, 0)}
end
```

**Key points:**

- `params` contains URL path parameters
- `session` accesses session data (user context, tokens)
- Return `{:ok, socket}` or `{:ok, socket, options}` with options like `layout: false`
- Mounting during HTTP request renders immediately; WebSocket reconnection preserves assigns unless explicitly changed

### Handle Params

`handle_params/3` processes URL and query string parameters, called after mount during initial HTTP render and triggered by navigation within the same LiveView:

```elixir
def handle_params(params, uri, socket) do
  {:noreply, socket}
end
```

**Execution order:**

- Always called after `mount/3`
- Useful for pagination, filtering, or URL-driven state
- Full URI available for custom parsing

## Callback Handlers

### Render Callback

`render/1` generates the template, invoked after mount and after state changes:

```elixir
def render(assigns) do
  ~H"""
  <div>
    <p>Count: <%= @assigns.count %></p>
    <button phx-click="increment">+</button>
  </div>
  """
end
```

**Options:**

- Use `~H` sigil for inline templates
- Reference assigns via `@name` shorthand
- Move templates to separate `.html.heex` files for large modules

### Handle Event

`handle_event/3` processes client-triggered events (button clicks, form changes):

```elixir
def handle_event("increment", _params, socket) do
  {:noreply, update(socket, :count, &(&1 + 1))}
end
```

**Event routing:**

- Events from `phx-click`, `phx-change`, `phx-submit` map to string event names
- Return `{:noreply, socket}` for updates or `{:reply, payload, socket}` for JS callbacks
- `_target` parameter identifies which input triggered `phx-change` on multi-field forms

### Handle Info

`handle_info/2` processes messages from other Elixir processes (PubSub, timers, async tasks):

```elixir
def handle_info({:event, data}, socket) do
  {:noreply, update(socket, :items, &(&1 ++ [data]))}
end
```

**Common patterns:**

- Subscribe in `mount/3`: `Phoenix.PubSub.subscribe(MyApp.PubSub, "channel")`
- Used for real-time updates from other users or background jobs
- Allows LiveView to react to external state changes

### Handle Async

`handle_async/3` receives results from asynchronous operations started with `start_async/3` or `assign_async/3`:

```elixir
def handle_async(:load_users, {:ok, users}, socket) do
  {:noreply, assign(socket, :users, users)}
end

def handle_async(:load_users, {:exit, reason}, socket) do
  {:noreply, assign(socket, :error, "Failed to load users")}
end
```

## Lifecycle Hooks

Server-side hooks attach to specific stages and can intercept callbacks:

- **`:mount`** — Executed via `on_mount/1`, runs before `mount/3`; return `{:halt, socket}` to skip mount
- **`:handle_params`** — Before `handle_params/3`
- **`:handle_event`** — Before `handle_event/3`
- **`:handle_info`** — Before `handle_info/2`
- **`:handle_async`** — Before `handle_async/3`
- **`:after_render`** — After template renders (useful for analytics, logging)

Example authentication hook:

```elixir
def on_mount(:ensure_authenticated, _params, session, socket) do
  if Map.has_key?(session, :user_id) do
    {:cont, socket}
  else
    {:halt, redirect(socket, to: "/login")}
  end
end
```

Attach in router:

```elixir
live "/protected", MyLive, on_mount: :ensure_authenticated
```

## Disconnection and Reconnection

LiveViews automatically recover state when clients reconnect (e.g., after network interruption). The same socket process resumes, and form values are restored if the form has an `id` and `phx-change` binding.

Disable recovery with `phx-auto-recover="ignore"` on specific forms when you need custom handling.

---

[← Back to main](phoenix_live_view-1.1.28.md)
**Version:** 1.1.28
