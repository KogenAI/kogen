# phoenix - Channels & Real-Time

## Core Concept

Phoenix Channels enable soft real-time communication between connected clients and servers. They support WebSocket and long-polling transports, allowing bidirectional message exchange. Common uses include chat applications, live notifications, multiplayer games, and sensor monitoring.

The channel system maintains persistent connections for each client, allowing the server to push updates without waiting for client requests. Messages can broadcast to all subscribers on a topic, even across multiple server nodes through an internal PubSub mechanism.

## Architecture

**Socket Handlers** authenticate connections and route messages. Define them in `lib/hello_web/channels/user_socket.ex`:

```elixir
defmodule HelloWeb.UserSocket do
  use Phoenix.Socket

  channel "room:*", HelloWeb.RoomChannel
  channel "user:*", HelloWeb.UserChannel

  def connect(params, socket, _connect_info) do
    {:ok, socket}
  end

  def id(socket), do: "user_socket:#{socket.assigns.user_id}"
end
```

**Channels** implement the business logic for specific topics. The `join/3` callback handles authorization:

```elixir
defmodule HelloWeb.RoomChannel do
  use Phoenix.Channel

  def join("room:lobby", _message, socket) do
    {:ok, socket}
  end

  def join("room:" <> _private_room, _params, socket) do
    {:error, %{reason: "unauthorized"}}
  end
end
```

## Joining and Messaging

Clients establish WebSocket connections and join topics through channels. On the client side:

```javascript
let channel = socket.channel("room:lobby");
channel
  .join()
  .receive("ok", (resp) => console.log("Joined"))
  .receive("error", (resp) => console.log("Failed"));

channel.on("new_message", (msg) => console.log(msg));
channel.push("new_message", { body: "Hello" });
```

On the server, handle incoming events with `handle_in/3`:

```elixir
def handle_in("new_message", %{"body" => body}, socket) do
  broadcast!(socket, "new_message", %{body: body, user: socket.assigns.user})
  {:noreply, socket}
end
```

## Broadcasting Messages

Broadcast to all subscribers on a topic:

```elixir
broadcast!(socket, "new_message", %{body: "Hello everyone"})
```

Broadcast to all subscribers except the current connection:

```elixir
broadcast_from!(socket, "new_message", %{body: "Hello others"})
```

Broadcast across the entire cluster to a specific topic:

```elixir
Phoenix.PubSub.broadcast(Hello.PubSub, "room:lobby", {:new_message, data})
```

## Process Messages

Handle messages from PubSub or other processes with `handle_info/2`:

```elixir
def handle_info({:new_notification, msg}, socket) do
  push(socket, "notification", %{message: msg})
  {:noreply, socket}
end
```

Subscribe to PubSub topics from within a channel:

```elixir
def join("room:" <> room_id, _params, socket) do
  Phoenix.PubSub.subscribe(Hello.PubSub, "room:#{room_id}")
  {:ok, socket}
end
```

## Intercepting Outgoing Messages

The `handle_out/3` callback intercepts messages before they're sent to clients, allowing filtering or transformation:

```elixir
def handle_out("new_message", payload, socket) do
  if authorized?(socket, payload) do
    push(socket, "new_message", payload)
  end
  {:noreply, socket}
end

def intercept(["new_message"])
```

## Authentication

Phoenix supports token-based authentication via `Phoenix.Token`, which is more suitable for long-lived connections than session-based approaches:

```elixir
def connect(%{"token" => token}, socket, _connect_info) do
  case Phoenix.Token.verify(socket, "user", token, max_age: 86400) do
    {:ok, user_id} -> {:ok, assign(socket, :user_id, user_id)}
    {:error, _reason} -> :error
  end
end
```

Generate tokens in controllers:

```elixir
def show(conn, _params) do
  token = Phoenix.Token.sign(conn, "user", conn.assigns.current_user.id)
  render(conn, "show.html", token: token)
end
```

## Reliability & Delivery Guarantees

The system offers at-most-once message delivery. Applications requiring guaranteed delivery should implement persistence and recovery mechanisms:

- Track message IDs sent to clients
- Store unacknowledged messages in the database
- Retransmit on client reconnection

## Building a Chat Example

Generate socket boilerplate:

```bash
mix phx.gen.socket User
```

Implement join callback for authorization, use `handle_in/3` to process incoming events, and `broadcast!/3` to send to all subscribers. This pattern scales from simple notification systems to complex real-time applications.

## Multi-Node Deployments

For clustered deployments with multiple server nodes:

- Use WebSocket transport (preferred) which maintains sticky connections
- Or configure Redis PubSub adapter for message distribution
- Or enable Erlang clustering for built-in distribution

---

[← Back to main](phoenix-1.8.9.md)
**Version:** 1.8.9
