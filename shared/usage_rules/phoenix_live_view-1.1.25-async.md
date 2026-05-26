# phoenix_live_view - Async Operations

## Assign Async

`assign_async/3` automatically wraps functions in tasks, storing results in an `AsyncResult` struct. Use it for simple async operations:

```elixir
def mount(_params, _session, socket) do
  {:ok,
   socket
   |> assign_async(:user, fn -> {:ok, fetch_user(socket.assigns.user_id)} end)
   |> assign_async(:posts, fn -> {:ok, fetch_posts(socket.assigns.user_id)} end)}
end
```

The `@user` and `@posts` assigns are `AsyncResult` structs with state tracking. In templates, match on the result:

```heex
<.async_result :let={user} async={@user}>
  <:loading>Loading user...</:loading>
  <:failed :let={_reason}>Failed to load user</:failed>
  <p><%= user.name %></p>
</.async_result>
```

The framework provides the `<.async_result>` component for displaying loading/error/success states. Use `AsyncResult.ok?/1` to check if data loaded:

```elixir
def render(%{user: user} = assigns) when AsyncResult.ok?(user) do
  ~H"""
  <p><%= user.ok %></p>
  """
end
```

## Start Async

`start_async/3` gives more control over async operations. Use it when you need custom handling:

```elixir
@impl true
def mount(_params, _session, socket) do
  socket = start_async(socket, :data_fetch, fn ->
    {:ok, load_expensive_data()}
  end)
  {:ok, socket}
end

@impl true
def handle_async(:data_fetch, {:ok, data}, socket) do
  {:noreply, assign(socket, :data, data)}
end

@impl true
def handle_async(:data_fetch, {:exit, reason}, socket) do
  {:noreply, put_flash(socket, :error, "Loading failed")}
end
```

The unique key (`:data_fetch`) identifies the async operation. `handle_async/3` receives the result: `{:ok, value}` or `{:exit, reason}`.

## Critical: Don't Pass Socket to Async Functions

Never pass the socket into async functions—it copies the entire struct to the task process:

```elixir
# ❌ WRONG: Copies socket to task
start_async(socket, :fetch, fn -> fetch_data(socket) end)

# ✅ CORRECT: Extract needed values
user_id = socket.assigns.user_id
start_async(socket, :fetch, fn -> fetch_data(user_id) end)
```

## Error Handling

Both `assign_async` and `start_async` isolate task failures. If a task crashes, the operation fails gracefully with `{:exit, reason}`:

```elixir
def handle_async(:critical, {:exit, reason}, socket) do
  Logger.error("Critical task failed: #{inspect(reason)}")
  {:noreply, put_flash(socket, :error, "Critical operation failed")}
end
```

Use `Process.get_stacktrace()` inside a task to log context about errors.

## Async with Parameters

Update async operations reactively:

```elixir
def handle_event("search", %{"query" => query}, socket) do
  socket = start_async(socket, :search, fn ->
    {:ok, search_items(query)}
  end)
  {:noreply, socket}
end

def handle_async(:search, {:ok, results}, socket) do
  {:noreply, assign(socket, :results, results)}
end
```

Running `start_async` with the same key replaces the previous async task.

## Tracking Multiple Async Operations

Use different keys for independent operations:

```elixir
socket =
  socket
  |> start_async(:user, fn -> {:ok, fetch_user(id)} end)
  |> start_async(:posts, fn -> {:ok, fetch_posts(id)} end)
  |> start_async(:comments, fn -> {:ok, fetch_comments(id)} end)
```

Handle each separately:

```elixir
def handle_async(:user, {:ok, user}, socket), do: {:noreply, assign(socket, :user, user)}
def handle_async(:posts, {:ok, posts}, socket), do: {:noreply, assign(socket, :posts, posts)}
def handle_async(:comments, {:ok, comments}, socket), do: {:noreply, assign(socket, :comments, comments)}
```

## Cancellation

Async operations run until completion or the LiveView terminates. To cancel, restart the operation:

```elixir
def handle_event("cancel-search", _value, socket) do
  {:noreply, assign(socket, :results, nil)}
end
```

The previous task continues in the background but its result is ignored when it completes. For true cancellation, pass a cancel token and check it periodically.

## Combining with Forms

Validate forms asynchronously:

```elixir
def handle_event("validate", %{"user" => params}, socket) do
  changeset = User.change_user(%User{}, params)

  socket = start_async(socket, :validation, fn ->
    {:ok, check_unique_email(params["email"])}
  end)

  {:noreply, assign(socket, :form, to_form(changeset))}
end

def handle_async(:validation, {:ok, valid?}, socket) do
  {:noreply, assign(socket, :email_available, valid?)}
end
```

---

[← Back to main](phoenix_live_view-1.1.25.md)
**Version:** 1.1.25
