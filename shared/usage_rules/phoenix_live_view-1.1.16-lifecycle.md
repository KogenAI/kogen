# phoenix_live_view - Lifecycle and State Management

## Core Lifecycle Callbacks

Phoenix LiveView executes callbacks in a specific sequence throughout component lifetime:

**Mount Phase:**
`mount/3` is the entry point invoked when a LiveView request arrives. It receives three arguments: params (URL parameters), session (authentication data), and socket. Mount executes twice in production: first during static HTML rendering, then again after WebSocket connection. Always check connection status with `connected?(socket)` when initialization depends on communication. Data loaded in mount executes once per lifecycle and persists across page patches.

```elixir
def mount(params, session, socket) do
  if connected?(socket) do
    {:ok, assign(socket, :state, fetch_initial_state())}
  else
    {:ok, socket}
  end
end
```

**Params Handling:**
`handle_params/3` executes after mount and whenever query parameters change via `push_patch`. The socket and params are provided along with the current URL. This callback handles query-dependent state, filtering, and pagination that should update when URLs change. Never load base data here—use mount instead, as handle_params fires on every URL patch and can cause redundant database queries.

**Rendering:**
`render/1` generates HEEx template output using assigns from the socket. LiveView automatically calls render after state changes and sends diffs to clients. Templates are automatically colocated when stored as `module_name.html.heex` in the same directory. Rendering is synchronous and must complete quickly to maintain responsiveness.

**Event Handling:**
`handle_event/3` processes client events from phx-click, phx-change, phx-submit bindings. It receives event name, parameters map, and socket. All user interactions route through this callback. Use pattern matching on event names for clarity.

**Message Processing:**
`handle_info/2` receives messages from other Elixir processes, enabling real-time updates from background tasks. This supports pub/sub subscriptions, internal message passing, and async task completion. Combined with `Phoenix.PubSub`, handle_info enables multi-user real-time features.

**Termination:**
`terminate/2` executes when LiveViews disconnect, providing cleanup opportunities. It receives reason and socket. Use this for unsubscribing from topics or canceling async tasks.

## State Management with Assigns

**Core Pattern:**
Use `assign/2` to update socket state. Changes trigger re-renders and client diffs. The socket accumulates assigns across the lifetime, making previous values available in all callbacks.

```elixir
def handle_event("submit", %{"form" => data}, socket) do
  case save_data(data) do
    {:ok, result} ->
      {:noreply, assign(socket, :saved, result)}
    {:error, changeset} ->
      {:noreply, assign(socket, :errors, changeset.errors)}
  end
end
```

**Change Tracking:**
LiveView automatically tracks assign changes and sends only diffs to clients. Avoid expensive computations in assigns when possible—LiveView will recalculate derived values on every render. Use computed properties only when necessary for template rendering.

**Private Data:**
Use `put_private/3` for change-tracked data that shouldn't update on modification. Private data follows normal change tracking but is separate from template-accessible assigns. This is useful for internal state that templates don't directly reference.

## Async Operations

**assign_async/3:**
Wraps async functions in supervised tasks with built-in error handling. Assigns a loading state initially, then updates when the async operation completes or fails.

```elixir
def mount(_params, _session, socket) do
  {:ok, assign_async(socket, :user, fn -> fetch_user() end)}
end
```

Results become available via `handle_async/3` callback:

```elixir
def handle_async(:user, {:ok, user}, socket) do
  {:noreply, assign(socket, :user, user)}
end

def handle_async(:user, {:exit, _reason}, socket) do
  {:noreply, put_flash(socket, :error, "Failed to load user")}
end
```

**start_async/3:**
Lower-level async wrapper for cases requiring custom handling. Returns a task reference for manual monitoring via handle_async.

## Flash Messages

Flash messages communicate temporary status updates without persisting in state:

```elixir
socket
|> put_flash(:info, "Changes saved successfully")
|> put_flash(:error, "Validation failed")
```

Flash messages clear after the next render, making them ideal for one-time notifications. Always clear flash in mount to prevent stale messages from previous pages.

## Navigation and State Transitions

**push_patch/2:**
Updates the URL and triggers handle_params without mounting a new LiveView. Maintains current state and connection, perfect for filter/pagination updates.

**push_navigate/2:**
Mounts a new LiveView at the target URL, useful for full page transitions. Previous state discards and new mount executes.

**redirect/2:**
Performs a full HTTP redirect, dropping the LiveView connection and triggering normal HTTP request/response.

---

[← Back to main](phoenix_live_view-1.1.16.md)
**Version:** 1.1.16
