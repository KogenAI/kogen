# phoenix - Channels & Real-Time Communication

## Overview

Phoenix Channels enable soft real-time communication with millions of connected clients using WebSockets with automatic fallback to long polling. Messages broadcast to connected clients without page refresh, supporting chat systems, live notifications, multiplayer games, IoT monitoring, and development tools.

Channels work seamlessly across multiple nodes/machines via Erlang clustering or Redis PubSub adapters, eliminating the need for external message brokers for many applications.

## Core Architecture

The communication flow involves five components:

1. **Endpoint** — Declares socket handlers at specific URLs (e.g., `/socket`)
2. **Socket Handlers** — Authenticate connections and establish initial state
3. **Channel Routes** — Match topic strings to channel modules (e.g., `"room:*"`)
4. **Channels** — Handle bidirectional events with `join/3`, `terminate/2`, `handle_in/3`, `handle_out/3`
5. **PubSub** — Distributes messages across nodes

## Setting Up Channels

**1. Configure the Endpoint:**

```elixir
defmodule HelloWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :hello

  socket "/socket", HelloWeb.UserSocket,
    websocket: [timeout: 45_000],
    longpoll: [timeout: 45_000]
end
```

**2. Create a Socket Handler:**

```elixir
defmodule HelloWeb.UserSocket do
  use Phoenix.Socket

  channel "room:*", HelloWeb.RoomChannel
  channel "user:*", HelloWeb.UserChannel

  def connect(params, socket) do
    {:ok, assign(socket, :user_id, params["user_id"])}
  end

  def id(socket) do
    "user_socket:#{socket.assigns.user_id}"
  end
end
```

**3. Create a Channel:**

```elixir
defmodule HelloWeb.RoomChannel do
  use Phoenix.Channel

  def join("room:" <> room_id, params, socket) do
    :ok = HelloWeb.Presence.track(socket, "user_#{socket.assigns.user_id}", %{
      online_at: inspect(System.system_time(:second))
    })
    send(self(), :after_join)
    {:ok, socket}
  end

  def handle_info(:after_join, socket) do
    push(socket, "presence_state", HelloWeb.Presence.list(socket))
    {:noreply, socket}
  end

  def handle_in("new_msg", %{"body" => body}, socket) do
    broadcast!(socket, "new_msg", %{
      user: socket.assigns.user_id,
      body: body,
      timestamp: System.system_time(:millisecond)
    })
    {:noreply, socket}
  end

  def handle_in("typing", _payload, socket) do
    broadcast_from!(socket, "user:typing", %{user: socket.assigns.user_id})
    {:noreply, socket}
  end

  def terminate(_reason, socket) do
    :ok
  end
end
```

## Client-Side JavaScript

**Connect to the socket:**

```javascript
import { Socket } from "phoenix";

const socket = new Socket("/socket", { params: { user_id: userId } });
socket.connect();

const channel = socket.channel("room:lobby", {});

channel.on("new_msg", (payload) => {
  let messageItem = document.createElement("p");
  messageItem.innerText = `[${new Date()}] ${payload.user}: ${payload.body}`;
  messagesContainer.appendChild(messageItem);
});

channel.on("user:typing", (payload) => {
  console.log(`User ${payload.user} is typing...`);
});

channel
  .join()
  .receive("ok", (resp) => console.log("Joined channel", resp))
  .receive("error", (resp) => console.log("Unable to join", resp));

// Send a message
document.getElementById("send-btn").addEventListener("click", () => {
  const input = document.getElementById("msg-input");
  channel.push("new_msg", { body: input.value });
  input.value = "";
});
```

## Channel Callbacks

**`join/3` — Called when a client joins a topic:**

```elixir
def join("room:" <> room_id, _params, socket) do
  if authorized?(socket, room_id) do
    {:ok, socket}
  else
    {:error, %{reason: "unauthorized"}}
  end
end
```

**`handle_in/3` — Called when a client sends a message:**

```elixir
def handle_in("new_msg", %{"body" => body}, socket) do
  broadcast!(socket, "new_msg", %{user: socket.assigns.user_id, body: body})
  {:noreply, socket}
end
```

**`handle_out/3` — Called before broadcasting to the channel (allows filtering):**

```elixir
def handle_out("new_msg", payload, socket) do
  push(socket, "new_msg", payload)
  {:noreply, socket}
end
```

**`terminate/2` — Called when a connection closes:**

```elixir
def terminate(reason, socket) do
  IO.puts("User #{socket.assigns.user_id} disconnected")
  :ok
end
```

## Broadcasting

**Broadcast to all connected clients:**

```elixir
broadcast!(socket, "new_msg", %{user: user_id, body: body})
```

**Broadcast to all except the sender:**

```elixir
broadcast_from!(socket, "user:typing", %{user: user_id})
```

**Broadcast using PubSub directly:**

```elixir
HelloWeb.PubSub.broadcast("room:lobby", "new_msg", %{user: user_id, body: body})
```

## Authentication with Tokens

Implement token-based authentication for long-running connections:

```elixir
# 1. Generate token in your authentication controller
defmodule HelloWeb.AuthController do
  def login(conn, %{"email" => email, "password" => password}) do
    case User.authenticate(email, password) do
      {:ok, user} ->
        token = Phoenix.Token.sign(HelloWeb.Endpoint, "user_id", user.id)
        json(conn, %{token: token})
      :error ->
        put_status(conn, 401) |> json(%{error: "Invalid credentials"})
    end
  end
end

# 2. Pass token to JavaScript
<script>
  const userToken = "<%= @user_token %>"
  const socket = new Socket("/socket", { params: { token: userToken } })
</script>

# 3. Verify token in Socket handler
def connect(%{"token" => token}, socket) do
  case Phoenix.Token.verify(HelloWeb.Endpoint, "user_id", token, max_age: 86400) do
    {:ok, user_id} ->
      {:ok, assign(socket, :user_id, user_id)}
    {:error, _reason} ->
      :error
  end
end
```

## Reconnection and Presence

**Automatic reconnection:**

Clients automatically reconnect using exponential backoff and rejoin previous topics.

**Track presence:**

```elixir
# In your channel
def join("room:" <> room_id, _params, socket) do
  :ok = HelloWeb.Presence.track(socket, "user_#{socket.assigns.user_id}", %{
    name: socket.assigns.user_name,
    online_at: inspect(System.system_time(:second))
  })

  present_users = Presence.list(socket)
  {:ok, present_users}
end

# On the client
channel.on("presence_state", state => {
  console.log("Users online:", state)
})

channel.on("presence_diff", diff => {
  console.log("Joins:", diff.joins)
  console.log("Leaves:", diff.leaves)
})
```

## Message Delivery Guarantees

Phoenix uses an **at-most-once** message delivery strategy. For stronger guarantees, implement application-level tracking:

```elixir
# Server-side: track message IDs
def handle_in("new_msg", %{"id" => msg_id, "body" => body}, socket) do
  broadcast!(socket, "new_msg", %{
    id: msg_id,
    user: socket.assigns.user_id,
    body: body
  })
  {:noreply, socket}
end

# Client-side: request missing messages on reconnect
channel.on("last_msg_id", payload => {
  const lastSeen = localStorage.getItem("last_msg_id") || 0
  if (payload.id > lastSeen) {
    localStorage.setItem("last_msg_id", payload.id)
  } else {
    channel.push("get_messages", { since: lastSeen })
  }
})
```

## Scaling Across Nodes

For multi-node deployments with long polling, use:

1. **Erlang clustering** (built-in) — Nodes communicate via Erlang distribution
2. **Redis PubSub adapter** — Nodes broadcast via a shared Redis instance

Configure in `config/prod.exs`:

```elixir
config :hello, HelloWeb.Endpoint,
  pubsub_server: Hello.PubSub,
  socket_options: [transport: :websocket]

config :hello, Hello.PubSub,
  adapter: Phoenix.PubSub.PG2  # Built-in clustering
  # or
  # adapter: Phoenix.PubSub.Redis,
  # url: System.get_env("REDIS_URL")
```

---

[← Back to main](phoenix-1.8.4.md)
**Version:** 1.8.4
