# phoenix_live_view - Async Operations and Background Tasks

## Asynchronous Operations Overview

LiveView provides two patterns for async work: **assign async** for common scenarios and **start async** for lower-level control.

### Critical Warning: Don't Copy the Socket

Never pass the socket into async functions. The socket is a large struct; passing it to a task process incurs expensive copying overhead for each operation:

```elixir
# ❌ WRONG: Expensive socket copying
start_async(:load_data, fn ->
  socket = socket  # ← Copied to task
  {:ok, fetch_data(socket)}
end)

# ✅ CORRECT: Extract only what you need
user_id = socket.assigns.user_id
start_async(:load_data, fn ->
  {:ok, fetch_data(user_id)}
end)
```

## Assign Async Pattern

`assign_async/3` simplifies common scenarios where you load data and assign it on completion:

```elixir
def mount(_params, _session, socket) do
  {:ok, assign_async(socket, :users, fn ->
    {:ok, %{users: Repo.all(User)}}
  end)}
end
```

Results wrap in `AsyncResult` structs that track states:

```heex
<%= case @users do %>
  <% {:loading} -> %>
    <p>Loading users...</p>

  <% {:ok, data} -> %>
    <ul>
      <%= for user <- data.users do %>
        <li><%= user.name %></li>
      <% end %>
    </ul>

  <% {:error, reason} -> %>
    <p>Failed to load: <%= reason %></p>
<% end %>
```

**Advantages:**

- Automatic progress tracking
- Built-in error handling
- Simplified template logic
- Automatic cancellation on component unmount

### Key Patterns

Load multiple assigns in parallel:

```elixir
def mount(_params, _session, socket) do
  {:ok,
   socket
   |> assign_async(:users, fn -> {:ok, %{users: Repo.all(User)}} end)
   |> assign_async(:posts, fn -> {:ok, %{posts: Repo.all(Post)}} end)
  }
end
```

Access context (user ID) before async:

```elixir
def mount(_params, %{"user_id" => user_id}, socket) do
  {:ok, assign_async(socket, :profile, fn ->
    # user_id is from session/mount params
    {:ok, %{profile: Repo.get!(User, user_id)}}
  end)}
end
```

## Start Async Pattern

`start_async/3` offers lower-level control, allowing manual state management via `handle_async/3`:

```elixir
def mount(_params, _session, socket) do
  socket = start_async(socket, :load_users, fn ->
    {:ok, Repo.all(User)}
  end)
  {:ok, assign(socket, :users, [])}
end

def handle_async(:load_users, {:ok, users}, socket) do
  {:noreply, assign(socket, :users, users)}
end

def handle_async(:load_users, {:exit, reason}, socket) do
  {:noreply, put_flash(socket, :error, "Failed to load users")}
end
```

**When to use:**

- Complex state transitions during loading/error
- Conditional retries or fallback logic
- Long-running operations with progress updates
- Multiple async operations with dependencies

## Async with Progress Tracking

Use `handle_info/2` to send progress updates from async tasks:

```elixir
def mount(_params, _session, socket) do
  {:ok,
   socket
   |> assign(:progress, 0)
   |> start_async(:import, fn ->
     {:ok, import_data()}
   end)
  }
end

defp import_data do
  for i <- 1..100 do
    # Send progress to LiveView
    send(self(), {:progress, i})
    Process.sleep(100)
    # Process item...
  end
end

def handle_info({:progress, percent}, socket) do
  {:noreply, assign(socket, :progress, percent)}
end
```

## Handling Async Errors

Both patterns support error handling:

**Assign Async:**

```heex
<%= case @data do %>
  <% {:error, "timeout"} -> %>
    <p>Request timed out</p>

  <% {:error, reason} -> %>
    <p>Error: <%= reason %></p>
<% end %>
```

**Start Async:**

```elixir
def handle_async(:operation, {:exit, reason}, socket) do
  {:noreply, put_flash(socket, :error, "Error: #{reason}")}
end
```

Return exit tuples from async functions to trigger error handling:

```elixir
def mount(_params, _session, socket) do
  {:ok, assign_async(socket, :data, fn ->
    case fetch_from_api() do
      {:ok, data} -> {:ok, %{data: data}}
      {:error, reason} -> {:error, reason}
    end
  end)}
end
```

## Cancellation

LiveView automatically cancels async operations when:

- The component/LiveView is unmounted
- A new async operation starts with the same key
- The process receives `shutdown` signal

Manual cancellation:

```elixir
defmodule MyLive do
  def handle_event("cancel", _params, socket) do
    # Stops the :load_data async operation
    {:noreply, cancel_async(socket, :load_data)}
  end
end
```

## Timeouts

Set default timeout for all async operations:

```elixir
def mount(_params, _session, socket) do
  socket = socket |> assign(:_timeout, 5000)
  {:ok, assign_async(socket, :data, fn -> ... end)}
end
```

Or per-operation:

```elixir
def mount(_params, _session, socket) do
  {:ok, assign_async(socket, :data, fn -> ... end, timeout: 10000)}
end
```

---

[← Back to main](phoenix_live_view-1.1.28.md)
**Version:** 1.1.28
