# Phoenix - Real-Time with Channels

## Channel Overview

Phoenix Channels enable soft real-time communication between connected clients and servers, supporting millions of simultaneously connected clients. The architecture combines WebSocket transport, topic-based subscription, and a publish-subscribe (PubSub) system that works across single or clustered servers.

## Connection Architecture

### Socket Setup

Each client establishes a single WebSocket connection through the socket module:

```elixir
defmodule MyApp.UserSocket do
  use Phoenix.Socket

  channel "room:*", MyApp.RoomChannel
  channel "notification:*", MyApp.NotificationChannel

  def connect(params, socket, _connect_info) do
    {:ok, socket}
  end

  def id(socket), do: "user_#{socket.assigns.user_id}"
end
```

The socket handler authenticates connections and assigns identifies the client session. Pattern-matched channels route incoming messages to appropriate channel modules.

## Channel Flow

1. **Client joins** — Connects via WebSocket and sends `join` message to topic
2. **Server handles join** — Channel module executes `join/3` callback
3. **Bidirectional messaging** — Client and server exchange messages
4. **Leave/Disconnect** — Connection closes, `terminate/2` executes

## Channel Callbacks

Implement channel behavior through callbacks:

```elixir
defmodule MyApp.RoomChannel do
  use Phoenix.Channel

  def join("room:lobby", _message, socket) do
    {:ok, socket}
  end

  def join("room:" <> _private, _message, socket) do
    {:error, %{reason: "unauthorized"}}
  end

  def handle_in("new_msg", %{"body" => body}, socket) do
    broadcast!(socket, "new_msg", %{body: body})
    {:noreply, socket}
  end

  def handle_in("ping", _payload, socket) do
    {:reply, {:ok, %{status: "pong"}}, socket}
  end

  def handle_out("new_msg", payload, socket) do
    push(socket, "new_msg", payload)
    {:noreply, socket}
  end

  def terminate(_reason, _socket) do
    :ok
  end
end
```

**Callback responsibilities:**

- `join/3` — Authenticate and authorize topic subscription
- `handle_in/3` — Process incoming client messages
- `handle_out/3` — Transform outgoing broadcast messages
- `terminate/2` — Cleanup when connection closes

## Broadcasting

Send messages to multiple clients:

```elixir
# Broadcast to all clients on topic
broadcast!(socket, "event_name", %{data: "value"})

# Broadcast to all except sender
broadcast_from!(socket, "event_name", %{data: "value"})

# Send to specific client
push(socket, "event_name", %{data: "value"})
```

Broadcasts work across all connected clients in the entire cluster—multiple nodes share PubSub data automatically through Erlang VM messaging or Redis adapters.

## Client-Side JavaScript

The official Phoenix JavaScript client connects and manages channels:

```javascript
import { Socket } from "phoenix";

const socket = new Socket("/socket", { params: { token: userToken } });
socket.connect();

const channel = socket.channel("room:lobby", {});

channel
  .join()
  .receive("ok", (resp) => console.log("Joined", resp))
  .receive("error", (resp) => console.log("Unable to join", resp));

channel.on("new_msg", (payload) => {
  console.log("Message received:", payload.body);
});

channel
  .push("new_msg", { body: "Hello" })
  .receive("ok", (resp) => console.log("Message sent", resp))
  .receive("error", (resp) => console.log("Send failed", resp));
```

## Topic Patterns

Topics follow `"topic"` or `"topic:subtopic"` convention, supporting wildcards:

```elixir
# Matches "room:lobby", "room:general", etc.
channel "room:*", MyApp.RoomChannel

# Matches "user:1:notification", "user:2:notification", etc.
channel "user:*:notification", MyApp.NotificationChannel

# Specific topic only
channel "broadcast", MyApp.BroadcastChannel
```

Extract wildcard segments in callbacks:

```elixir
def join("room:" <> room_id, _message, socket) do
  {:ok, assign(socket, :room_id, room_id)}
end
```

## PubSub Adapters

### Erlang VM PubSub (Default)

Works within a single runtime via native message passing. Suitable for development and single-server deployments.

```elixir
# config/config.exs
config :my_app, MyApp.PubSub,
  adapter: Phoenix.PubSub.PG2
```

### Redis Adapter

For distributed systems with multiple nodes:

```elixir
config :my_app, MyApp.PubSub,
  adapter: Phoenix.PubSub.Redis,
  url: "redis://localhost:6379"
```

## Fault Tolerance

### Automatic Reconnection

Clients automatically attempt reconnection using exponential backoff when the connection drops. JavaScript client handles this transparently.

### Message Buffering

Outgoing messages buffer for 5 seconds by default if the connection drops, allowing clients that quickly reconnect to receive queued messages. Configure with:

```elixir
socket "ws", Phoenix.Socket,
  websocket: [timeout: 45000]
```

### Delivery Guarantees

Phoenix uses at-most-once delivery semantics by default—messages sent during disconnection are not guaranteed delivery. Implement application-level acknowledgments or message persistence for at-least-once guarantees:

```elixir
def handle_in("new_msg", payload, socket) do
  # Store message in database
  MyApp.Repo.insert(%Message{...})

  broadcast!(socket, "new_msg", payload)
  {:reply, :ok, socket}
end
```

## Transport Options

### WebSockets

Primary persistent connection mechanism with full-duplex communication. Supported in modern browsers.

```elixir
socket "ws", Phoenix.Socket,
  websocket: [
    path: "/socket",
    timeout: 45_000,
    compress: true
  ]
```

### Long Polling

Fallback transport for environments where WebSocket is unavailable. Clients poll periodically for new messages.

```elixir
socket "ws", Phoenix.Socket,
  longpoll: [
    path: "/socket",
    period: 30_000
  ]
```

Enable both transports for fallback support:

```elixir
socket "ws", Phoenix.Socket,
  websocket: [path: "/socket"],
  longpoll: [path: "/socket"]
```

---

[← Back to main](phoenix-1.8.7.md)
**Version:** 1.8.7
