# absinthe_phoenix

GraphQL subscriptions integration for Phoenix applications via WebSocket connections. Enables real-time bidirectional communication between clients and GraphQL servers using Absinthe.

## Quick Start

**Installation:**

Add to `mix.exs` dependencies:

```elixir
defp deps do
  [
    {:absinthe_phoenix, "~> 2.0.0"}
  ]
end
```

**System Requirements:**

- Elixir 1.10 or higher
- Phoenix 1.5 or higher

## Core Concepts

### WebSocket-based Subscriptions

Absinthe.Phoenix bridges GraphQL subscriptions with Phoenix WebSocket channels. Clients connect via WebSocket to receive real-time updates pushed by the server.

### PubSub Architecture

Real-time updates flow through Phoenix PubSub:

1. Server publishes events to a topic
2. Subscriptions listening on that topic receive notifications
3. GraphQL resolver executes and returns data to subscribed clients

### Key Components

- **Absinthe.Subscription**: Core subscription handler in supervisor
- **Absinthe.Phoenix.Socket**: WebSocket socket module configuration
- **PubSub Topics**: Named channels for broadcasting updates
- **Subscription Resolvers**: Field resolvers that return subscription streams

## Configuration

### 1. Add to Application Supervisor

In `lib/myapp/application.ex`:

```elixir
def start(_type, _args) do
  children = [
    ...
    {Absinthe.Subscription, MyAppWeb.Endpoint}
  ]
  Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)
end
```

### 2. Configure Socket Module

In `lib/myapp_web/channels/user_socket.ex`:

```elixir
defmodule MyAppWeb.UserSocket do
  use Phoenix.Socket
  use Absinthe.Phoenix.Socket,
    schema: MyAppWeb.Schema

  def connect(_params, socket) do
    {:ok, socket}
  end

  def id(_socket), do: nil
end
```

### 3. Enable Endpoint Integration

In `lib/myapp_web/endpoint.ex`:

```elixir
use Absinthe.Phoenix.Endpoint
```

### 4. Add GraphiQL Route (Optional)

In `lib/myapp_web/router.ex`:

```elixir
forward "/graphiql", Absinthe.Plug.GraphiQL,
  schema: MyAppWeb.Schema,
  socket: MyAppWeb.UserSocket
```

## Best Practices

### 1. Define Clear PubSub Topics

Use namespaced topic strings for clarity:

```elixir
# Good: Specific and hierarchical
"messages:#{user_id}"
"posts:#{post_id}:comments"

# Avoid: Generic or ambiguous names
"updates"
"data"
```

### 2. Implement Authentication in Socket

Validate user credentials before allowing subscriptions:

```elixir
def connect(%{"token" => token}, socket) do
  case authenticate_token(token) do
    {:ok, user_id} -> {:ok, assign(socket, :user_id, user_id)}
    :error -> :error
  end
end
```

### 3. Broadcast Events from Mutations

Update subscriptions when data changes:

```elixir
def create_post(_parent, %{"title" => title}, %{context: %{user_id: user_id}}) do
  with {:ok, post} <- create_and_broadcast(title, user_id) do
    Phoenix.PubSub.broadcast(
      MyApp.PubSub,
      "posts:#{user_id}",
      {:post_created, post}
    )
    {:ok, post}
  end
end
```

### 4. Clean Subscription Cancellation

Ensure resources are released when subscriptions end:

```elixir
subscription do
  field :message_created, :message do
    config(fn _args, %{context: %{user_id: user_id}} ->
      {:ok, topic: "messages:#{user_id}"}
    end)

    resolve(fn %{message: message}, _args, _info ->
      {:ok, message}
    end)
  end
end
```

### 5. Error Handling in Subscriptions

Return proper GraphQL errors rather than crashing:

```elixir
def subscribe(_parent, _args, _info) do
  {:ok, topic: "events"}
rescue
  e in CustomError -> {:error, e.message}
end
```

### 6. Resource Limits

Monitor WebSocket connections to prevent resource exhaustion:

- Limit concurrent subscriptions per user
- Implement timeouts for inactive connections
- Use backpressure mechanisms for high-throughput topics

---

**Version:** 2.0.3
**Source:** [hexdocs.pm/absinthe_phoenix](https://hexdocs.pm/absinthe_phoenix/)
**Generated:** 2025-10-28
