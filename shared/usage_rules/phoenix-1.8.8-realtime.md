# phoenix - Real-Time with Channels and Presence

## Channels Overview

Phoenix Channels enable bidirectional real-time communication with millions of clients via WebSocket. As the framework states: "Channels are pretty simple. First, clients connect to the server using some transport, like WebSocket. Once connected, they join one or more topics."

Common use cases: chat systems, live notifications, collaborative applications, multiplayer games, IoT monitoring, live dashboards.

## Channel Architecture

### Socket Handler

Establish connections and authenticate clients at the endpoint level:

```elixir
# lib/myapp_web/channels/user_socket.ex
defmodule MyappWeb.UserSocket do
  use Phoenix.Socket

  channel "room:*", MyappWeb.RoomChannel
  channel "user:*", MyappWeb.UserChannel

  def connect(params, socket, _connect_info) do
    case authenticate_user(params) do
      {:ok, user_id} -> {:ok, assign(socket, :user_id, user_id)}
      :error -> :error
    end
  end

  def id(socket), do: "user_socket:#{socket.assigns.user_id}"

  defp authenticate_user(params) do
    # Verify authentication token
    {:ok, params["user_id"]}
  end
end
```

### Channel Callbacks

Handle incoming messages and manage subscriptions:

```elixir
defmodule MyappWeb.RoomChannel do
  use Phoenix.Channel

  def join("room:" <> room_id, _message, socket) do
    # Optional: check authorization
    if authorized?(socket, room_id) do
      {:ok, assign(socket, :room_id, room_id)}
    else
      {:error, %{reason: "unauthorized"}}
    end
  end

  # Handle incoming messages from client
  def handle_in("new_message", %{"body" => body}, socket) do
    broadcast(socket, "message", %{
      user_id: socket.assigns.user_id,
      body: body,
      timestamp: DateTime.utc_now()
    })

    {:noreply, socket}
  end

  # Handle messages from other processes (PubSub)
  def handle_out("message", payload, socket) do
    push(socket, "message", payload)
    {:noreply, socket}
  end

  def handle_info({:new_notification, data}, socket) do
    push(socket, "notification", data)
    {:noreply, socket}
  end

  defp authorized?(_socket, _room_id), do: true
end
```

## Broadcasting Messages

### Broadcast to Topic

Send to all subscribers of a topic:

```elixir
# Broadcast to all clients in "room:123"
Phoenix.PubSub.broadcast(
  Myapp.PubSub,
  "room:123",
  {:message, %{user: "Alice", text: "Hello!"}}
)

# From within a channel
broadcast(socket, "message", %{user: "Alice", text: "Hello!"})
```

### Direct Push

Send to a specific socket:

```elixir
push(socket, "event_name", %{data: "payload"})
```

### Broadcast Except Self

Send to all subscribers except the sender:

```elixir
broadcast_from(socket, "user_joined", %{user_id: socket.assigns.user_id})
```

## Multi-Server Clustering

By default, Long-Polling transport requires coordination across servers. Options:

1. **Erlang VM Clustering** — Connect Erlang nodes directly (requires same network)
2. **Redis PubSub Adapter** — Use external PubSub service
3. **Sticky Sessions** — Load balancer routes same user to same server

Configure Redis adapter:

```elixir
# config/prod.exs
config :myapp, Myapp.PubSub,
  adapter: Phoenix.PubSub.Redis,
  url: System.get_env("REDIS_URL")
```

## Presence Tracking

Track real-time user presence without a database:

```elixir
# lib/myapp_web/channels/presence.ex
defmodule MyappWeb.Presence do
  use Phoenix.Presence,
    otp_app: :myapp,
    pubsub_server: Myapp.PubSub
end

# In your channel
def join("room:" <> room_id, _params, socket) do
  send(self(), :after_join)
  {:ok, assign(socket, :room_id, room_id)}
end

def handle_info(:after_join, socket) do
  {:ok, _} = Presence.track(socket, "user:#{socket.assigns.user_id}", %{
    online_at: inspect(System.system_time(:seconds)),
    user_id: socket.assigns.user_id
  })

  push(socket, "presence_state", Presence.list(socket))
  {:noreply, socket}
end

def handle_out("presence_diff", msg, socket) do
  push(socket, "presence_diff", msg)
  {:noreply, socket}
end
```

Client-side with Phoenix.JS:

```javascript
let channel = socket.channel("room:123");

channel.on("presence_state", (state) => {
  console.log("Users online:", state);
});

channel.on("presence_diff", (diff) => {
  console.log("Presence update:", diff);
});

channel.join();
```

## Message Delivery Guarantees

Phoenix provides **at-most-once delivery** by default:

- Messages are lost if the client disconnects before receiving
- No built-in persistence across disconnections

For stronger guarantees, implement custom tracking:

```elixir
# Track client's last seen message ID
defmodule MyappWeb.MessageChannel do
  def join("messages:" <> room_id, %{"last_seen_id" => last_seen}, socket) do
    # Send any missed messages since last_seen_id
    missed = get_missed_messages(room_id, last_seen)
    {:ok, assign(socket, :last_seen_id, last_seen), missed}
  end
end
```

## Broadcasting from Outside Channels

Send messages from any process:

```elixir
# From a controller
def notify_users(conn, _params) do
  Phoenix.PubSub.broadcast(
    Myapp.PubSub,
    "notifications",
    {:alert, %{message: "Something happened!"}}
  )

  send_resp(conn, 200, "Notification sent")
end

# Listen in a channel
def handle_out("alert", message, socket) do
  push(socket, "alert", message)
  {:noreply, socket}
end
```

## Common Patterns

### Typing Indicators

Show when other users are typing:

```elixir
def handle_in("typing", _params, socket) do
  broadcast_from(socket, "user_typing", %{
    user_id: socket.assigns.user_id
  })
  {:noreply, socket}
end

def handle_in("stop_typing", _params, socket) do
  broadcast_from(socket, "user_stop_typing", %{
    user_id: socket.assigns.user_id
  })
  {:noreply, socket}
end
```

### Rate Limiting

Prevent message flooding:

```elixir
def join("room:" <> _room_id, _message, socket) do
  {:ok, assign(socket, :message_count, 0, :timer, 0)}
end

def handle_in("message", %{"body" => body}, socket) do
  case check_rate_limit(socket) do
    :ok ->
      broadcast(socket, "message", %{user_id: socket.assigns.user_id, body: body})
      {:noreply, increment_count(socket)}
    :limited ->
      {:reply, {:error, "Too many messages"}, socket}
  end
end
```

---

[← Back to main](phoenix-1.8.8.md)  
**Version:** 1.8.8
