# Phoenix 1.8.1 - Real-Time Communication with Channels

## Core Concept

Phoenix Channels enable real-time bidirectional communication between servers and clients. The framework describes them as enabling "soft real-time communication with and between millions of connected clients." Channels power chat applications, notifications, collaborative editing, location tracking, multiplayer games, and IoT device monitoring.

## Architecture Overview

**Connection Flow**: Clients establish persistent connections using WebSocket or long polling protocols, then join specific topics to send and receive messages.

**Message Broadcasting**: Servers can "broadcast messages to all clients subscribed to a certain topic," with messages distributed across clustered nodes via an internal PubSub mechanism.

**Transport Options**: WebSocket for efficient full-duplex communication (preferred), and long-polling as fallback for environments with restrictive proxies.

## Key Use Cases

- Chat applications and messaging APIs
- Real-time news updates and alerts
- Location tracking for vehicles or participants
- Multiplayer game events
- IoT device monitoring and control
- Live dashboards and metrics
- Collaborative document editing

## Implementation Steps

### 1. Generate UserSocket Module

```bash
mix phx.gen.socket User
```

Creates `lib/hello_web/channels/user_socket.ex`:

```elixir
defmodule HelloWeb.UserSocket do
  use Phoenix.Socket

  # Channels
  channel "room:*", HelloWeb.RoomChannel
  channel "notification:*", HelloWeb.NotificationChannel

  # Socket authentication
  @impl true
  def connect(%{"token" => token}, socket, _connect_info) do
    case verify_token(token) do
      {:ok, user_id} ->
        {:ok, assign(socket, :user_id, user_id)}
      :error ->
        :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  @impl true
  def id(socket), do: "user_socket:#{socket.assigns.user_id}"

  defp verify_token(token) do
    Phoenix.Token.verify(HelloWeb.Endpoint, "user_socket", token, max_age: 86400)
  end
end
```

### 2. Define Channels

```elixir
defmodule HelloWeb.RoomChannel do
  use Phoenix.Channel

  @impl true
  def join("room:" <> room_id, _payload, socket) do
    # Authorization check
    if authorized?(socket, room_id) do
      :ok
    else
      :error
    end
  end

  def join(_room, _params, _socket), do: :error

  @impl true
  def handle_in("new_msg", %{"body" => body}, socket) do
    # Broadcast to all subscribers
    broadcast(socket, "new_msg", %{
      user_id: socket.assigns.user_id,
      body: body
    })
    {:noreply, socket}
  end

  @impl true
  def handle_info({:send_notification, msg}, socket) do
    push(socket, "notification", msg)
    {:noreply, socket}
  end

  defp authorized?(socket, room_id) do
    # Check if user can access this room
    true
  end
end
```

### 3. Client-Side Connection

JavaScript client establishes connection:

```javascript
// web/js/socket.js
let socket = new Socket("/socket", {
  params: { token: window.userToken },
});

socket.connect();

// Join a channel
let channel = socket.channel("room:42", {});
channel
  .join()
  .receive("ok", (resp) => console.log("Joined successfully", resp))
  .receive("error", (resp) => console.log("Unable to join", resp));

// Send and receive messages
channel
  .push("new_msg", { body: "Hello" })
  .receive("ok", () => console.log("Message sent"));

channel.on("new_msg", (payload) => {
  console.log("New message:", payload);
});

// Listen for server-initiated messages
channel.on("notification", (payload) => {
  console.log("Notification:", payload);
});
```

## Broadcasting Messages

Broadcast to all subscribers:

```elixir
# From within a channel
broadcast(socket, "event_name", %{data: "value"})

# From elsewhere (controller, context)
HelloWeb.Endpoint.broadcast("room:42", "event_name", %{data: "value"})

# Broadcast except sender
broadcast_from(socket, "event_name", %{data: "value"})
```

## Authentication with Tokens

Phoenix uses token-based authentication for long-lived connections:

```elixir
# In router
def get_token(conn, _params) do
  token = Phoenix.Token.sign(HelloWeb.Endpoint, "user_socket", user_id)
  json(conn, %{token: token})
end

# Client receives token and passes in socket params
let socket = new Socket("/socket", {
  params: { token: token }
})
```

## Presence Tracking

Track which users are connected to which channels:

```elixir
defmodule HelloWeb.Presence do
  use Phoenix.Presence, otp_app: :hello, pubsub_server: Hello.PubSub
end

# In channel
@impl true
def join("room:" <> room_id, payload, socket) do
  send(self(), :after_join)
  {:ok, socket}
end

def handle_info(:after_join, socket) do
  {:ok, _} = Presence.track(socket, "user:#{socket.assigns.user_id}", %{
    online_at: inspect(System.system_time(:second))
  })

  push(socket, "presence_state", Presence.list(socket))
  {:noreply, socket}
end

# Client receives presence updates
channel.on("presence_state", state => {
  console.log("Active users:", state)
})

channel.on("presence_diff", diff => {
  console.log("User joined/left", diff)
})
```

## Reliability Considerations

**Automatic Reconnection**: The client library implements automatic reconnection with exponential backoff when connections drop.

**Message Queuing**: Messages sent while disconnected are queued and transmitted upon reconnection.

**Delivery Guarantees**: Phoenix uses "at-most-once" message delivery rather than guaranteed persistence. For critical messages, implement application-level acknowledgments.

## Long-Polling Implications

For applications using long-polling instead of WebSocket:

> "If you want Long-Polling to work properly, your application must either implement Erlang clustering, use alternative pub/sub adapters like Redis, or enforce sticky sessions."

This requirement stems from long-polling's reliance on repeated requests; without these mechanisms, users may connect to different servers and lose session state.

## Best Practices

- Use WebSocket transport when possible for efficiency
- Always authenticate socket connections with tokens
- Validate authorization in `join/3` callbacks
- Implement presence tracking for multi-user features
- Broadcast only necessary data to avoid bandwidth waste
- Use topic namespaces (`room:*`, `notification:*`) for organization
- Implement heartbeats or liveness checks for long connections
- Consider Redis pub/sub adapter for multi-server deployments
- Test channel behavior with `Phoenix.ChannelTest` in tests
- Document channel topics and message formats clearly

---

[← Back to main](phoenix-1.8.1.md)
**Version:** 1.8.1
