# phoenix_pubsub

A distributed pub/sub platform for the Phoenix Framework, enabling real-time communication across nodes in a cluster. Phoenix.PubSub provides topic-based message broadcasting and presence tracking with support for multiple adapter backends.

## Quick Start

### Installation

Add to `mix.exs`:

```elixir
def deps do
  [
    {:phoenix_pubsub, "~> 2.2"}
  ]
end
```

### Basic Setup

Start the PubSub server in your application supervisor:

```elixir
children = [
  {Phoenix.PubSub, name: MyApp.PubSub}
]

Supervisor.start_link(children, strategy: :one_for_one)
```

### Publish and Subscribe

**Subscribe to a topic:**

```elixir
Phoenix.PubSub.subscribe(MyApp.PubSub, "user:123")
```

**Broadcast a message:**

```elixir
Phoenix.PubSub.broadcast(MyApp.PubSub, "user:123", {:user_updated, user})
```

**Receive messages in your process:**

```elixir
def handle_info({:user_updated, user}, state) do
  IO.inspect(user)
  {:noreply, state}
end
```

## Core Concepts

### Topics

Topics are strings used to organize subscribers into logical groups. Convention is hierarchical with colon separators:

- `"user:123"` - User-specific updates
- `"room:456"` - Chat room messages
- `"notifications"` - Global notifications

### Message Broadcasting

Three broadcast variants:

**Broadcast to all subscribers:**

```elixir
Phoenix.PubSub.broadcast(pubsub, topic, message)
```

**Broadcast excluding sender:**

```elixir
Phoenix.PubSub.broadcast_from(pubsub, from_pid, topic, message)
```

**Async broadcast (non-blocking):**

```elixir
Phoenix.PubSub.broadcast_async(pubsub, topic, message)
```

### Presence Tracking

Track which processes are subscribed to a topic:

```elixir
Phoenix.Presence.track(pubsub, pid, topic, key, metadata)
Phoenix.Presence.untrack(pubsub, pid, topic)
Phoenix.Presence.list(pubsub, topic)
```

### Adapters

Phoenix.PubSub supports multiple backends:

**PG2 Adapter** (default, single-node):

- Uses Erlang's Process Group 2
- Suitable for development and single-node deployments
- No external dependencies

**Redis Adapter** (multi-node):

- `{:phoenix_pubsub_redis, "~> 2.1"}` for distributed systems
- Requires Redis server
- Best for clustered deployments

**RabbitMQ Adapter** (multi-node):

- `{:phoenix_pubsub_rabbitmq, "~> 2.0"}` for complex routing
- Full AMQP support

## Configuration

### Supervisor Configuration

```elixir
{Phoenix.PubSub,
  name: MyApp.PubSub,
  adapter: Phoenix.PubSub.PG2,
  pool_size: 1
}
```

### Redis Adapter Configuration

```elixir
{Phoenix.PubSub,
  name: MyApp.PubSub,
  adapter: Phoenix.PubSub.Redis,
  url: "redis://localhost:6379",
  node_name: node()
}
```

### Key Options

- `name` - Registered name for the PubSub server (required)
- `adapter` - Backend adapter module (default: PG2)
- `pool_size` - Number of connection pool workers (PG2: 1, Redis: varies)
- `node_name` - Unique node identifier in cluster (Redis adapter)

## Best Practices

### Topic Design

- Use hierarchical naming: `resource:id:action`
- Keep topic names relatively short
- Use lowercase with colons as separators
- Avoid dynamic topic generation without structure

### Error Handling

Always handle subscription failures:

```elixir
case Phoenix.PubSub.subscribe(MyApp.PubSub, topic) do
  :ok -> {:noreply, state}
  {:error, reason} -> handle_error(reason)
end
```

### Memory Considerations

- Unsubscribe when processes terminate
- Use `broadcast_from/4` to avoid self-messaging
- Monitor long-lived subscriptions in high-throughput systems

### Clustering

For distributed deployments:

1. Use Redis or RabbitMQ adapter (not PG2)
2. Ensure all nodes share the same adapter configuration
3. Use consistent `node_name` across restarts
4. Test failover scenarios in development

### Channel Integration

In Phoenix channels, PubSub is used implicitly:

```elixir
defmodule MyApp.RoomChannel do
  use Phoenix.Channel

  def join("room:123", _params, socket) do
    {:ok, socket}
  end

  def handle_in("message", payload, socket) do
    broadcast(socket, "message", payload)
    {:noreply, socket}
  end
end
```

### Testing

Exclude clustered tests when epmd daemon is unavailable:

```bash
mix test --exclude clustered
```

For unit tests, PG2 adapter is sufficient and doesn't require external services.

## Common Patterns

### User-Specific Updates

```elixir
# Notify user when profile changes
Phoenix.PubSub.broadcast(
  MyApp.PubSub,
  "user:#{user_id}:profile",
  {:profile_updated, user}
)
```

### Room/Channel Broadcasting

```elixir
# Broadcast to all room subscribers
Phoenix.PubSub.broadcast(
  MyApp.PubSub,
  "room:#{room_id}",
  {:new_message, message}
)
```

### Cross-Service Communication

```elixir
# Notify about async job completion
Phoenix.PubSub.broadcast(
  MyApp.PubSub,
  "job:#{job_id}",
  {:job_completed, result}
)
```

## Important Gotchas

1. **No message persistence** - Messages are fire-and-forget; no queue if subscriber doesn't exist
2. **Process-based only** - Subscribers must be Elixir processes with message handling
3. **PG2 doesn't cluster** - Use Redis/RabbitMQ for multi-node deployments
4. **No authentication** - All subscribers can receive all published messages on a topic
5. **Topic isolation** - Topics are completely isolated; no pattern matching or wildcards

---

**Version:** 2.2.0  
**Source:** https://github.com/phoenixframework/phoenix_pubsub/tree/v2.2.0  
**Docs:** https://hexdocs.pm/phoenix_pubsub  
**Generated:** 2026-06-17
