# phoenix_live_view - Asynchronous Operations & Streams

## Async Operations Overview

LiveView provides two approaches for handling asynchronous work:

1. **`assign_async/3`** - Simplified API with automatic loading/error states
2. **`start_async/3`** - Lower-level control for complex scenarios

## assign_async/3 - Simplified Async

`assign_async/3` wraps functions in managed tasks, automatically handling loading/error states via AsyncResult structures.

```elixir
def mount(_params, _session, socket) do
  {:ok, assign_async(socket, :user, fn -> {:ok, fetch_user()} end)}
end
```

### AsyncResult Structure

Results are wrapped in an `AsyncResult` with three possible states:

```elixir
{:ok, value}      # Successfully loaded
{:error, reason}  # Failed during execution
:loading          # Currently processing
```

### Handling Async Results in Templates

Use the `<.async_result>` component to display state-dependent content:

```elixir
<.async_result :let={user} assign={@user}>
  <:loading>
    Loading user data...
  </:loading>
  <:failed :let={reason}>
    Error: {reason}
  </:failed>
  <p>User: {user.name}</p>
</.async_result>
```

### Multiple Async Operations

Load multiple async assigns simultaneously:

```elixir
def mount(_params, _session, socket) do
  socket
  |> assign_async(:user, fn -> {:ok, fetch_user()} end)
  |> assign_async(:posts, fn -> {:ok, fetch_posts()} end)
end
```

### Error Handling

Async operations automatically track errors without crashing:

```elixir
<.async_result :let={data} assign={@data}>
  <:failed :let={reason}>
    <div class="error">
      Failed to load: {inspect(reason)}
    </div>
  </:failed>
  <!-- success content -->
</.async_result>
```

## start_async/3 - Advanced Async

For scenarios requiring manual state management or complex error handling:

```elixir
def mount(_params, _session, socket) do
  {:ok, start_async(socket, :fetch_data, &do_fetch/0)}
end

defp do_fetch do
  # Perform async work
  {:ok, result}
end

def handle_async(:fetch_data, {:ok, result}, socket) do
  {:noreply, assign(socket, data: result)}
end

def handle_async(:fetch_data, {:exit, reason}, socket) do
  {:noreply, assign(socket, error: "Failed: #{reason}")}
end
```

### handle_async/3 Callback

Receives results from async tasks started with `start_async/3`:

```elixir
def handle_async(name, result, socket) do
  case result do
    {:ok, value} ->
      {:noreply, assign(socket, name => value)}
    {:exit, reason} ->
      {:noreply, assign(socket, error: reason)}
  end
end
```

**Returns:**

- `{:noreply, socket}` - Process result and continue
- `:error` - Retry the async operation
- Any other value - Retry indefinitely

### Concurrent Async Tasks

Run multiple independent async operations:

```elixir
socket
|> start_async(:fetch_user, &fetch_user/0)
|> start_async(:fetch_posts, &fetch_posts/0)
|> start_async(:fetch_comments, &fetch_comments/0)

def handle_async(:fetch_user, {:ok, user}, socket) do
  {:noreply, assign(socket, user: user)}
end

def handle_async(:fetch_posts, {:ok, posts}, socket) do
  {:noreply, assign(socket, posts: posts)}
end

def handle_async(:fetch_comments, {:ok, comments}, socket) do
  {:noreply, assign(socket, comments: comments)}
end
```

## Streams for Large Collections

Streams enable efficient handling of large collections without server-side resource overhead. They support bulk insertion, individual item management, and client-side limits.

### Initializing Streams

```elixir
def mount(_params, _session, socket) do
  {:ok, stream(socket, :items, [])}
end
```

### Inserting Items

```elixir
# Insert at end (default)
stream_insert(socket, :items, item)

# Insert at beginning
stream_insert(socket, :items, item, at: 0)

# Insert at specific position
stream_insert(socket, :items, item, at: 5)
```

### Deleting Items

```elixir
stream_delete(socket, :items, item)
```

### Rendering Streams

```elixir
<ul>
  <li :for={{id, item} <- @streams.items} id={id}>
    {item.name}
  </li>
</ul>
```

### Async Streaming

Load items asynchronously into a stream:

```elixir
def mount(_params, _session, socket) do
  {:ok, stream(socket, :items, [])}
end

def handle_event("load_more", _params, socket) do
  {:noreply, stream_async(socket, :items, fn -> load_paginated_items() end)}
end
```

### Stream Configuration

Set client-side limits to prevent overwhelming browsers:

```elixir
stream(socket, :items, [], dom_id: fn {id, _item} -> "item-#{id}" end)
```

## PubSub for Real-Time Updates

Combine async operations with PubSub for broadcast capabilities:

```elixir
def mount(_params, _session, socket) do
  Phoenix.PubSub.subscribe(MyApp.PubSub, "updates")
  {:ok, assign(socket, items: [])}
end

def handle_info({:new_item, item}, socket) do
  {:noreply, stream_insert(socket, :items, item, at: 0)}
end
```

## Best Practices

**Use assign_async/3 by Default:** Start with `assign_async/3` for simpler, cleaner code. Only use `start_async/3` when you need advanced error handling.

**Handle Disconnections:** Async tasks continue running even if the client disconnects. Design cleanup strategies:

```elixir
def handle_async(:long_task, {:ok, result}, socket) do
  # Client may have disconnected; still proceed
  {:noreply, assign(socket, result: result)}
end
```

**Limit Concurrent Tasks:** Avoid spawning unlimited concurrent async operations. Use a semaphore or queue pattern for controlled concurrency.

**Stream Large Data:** For collections exceeding thousands of items, use streams instead of loading everything into assigns.

```elixir
# Good for large datasets
def mount(_params, _session, socket) do
  {:ok, stream(socket, :posts, Post.stream())}
end

# Less efficient for large collections
def mount(_params, _session, socket) do
  {:ok, assign(socket, posts: Post.all())}
end
```

**Timeout Protection:** Set timeouts on async operations to prevent hanging:

```elixir
def handle_async(:fetch, result, socket) do
  case result do
    {:exit, :timeout} ->
      {:noreply, assign(socket, error: "Request timed out")}
    _ ->
      {:noreply, assign(socket, result: result)}
  end
end
```

---

[← Back to main](phoenix_live_view-1.1.32.md)  
**Version:** 1.1.32
