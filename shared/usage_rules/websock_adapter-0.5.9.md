# websock_adapter

WebSockAdapter is a WebSocket adapter for Phoenix 1.6+ that provides a standardized interface for handling WebSocket connections. It abstracts WebSocket transport details, allowing Phoenix to work with different WebSocket implementations while maintaining a consistent API.

## Quick Start

### Installation

Add to `mix.exs`:

```elixir
def deps do
  [
    {:websock_adapter, "~> 0.5.9"}
  ]
end
```

### Basic Configuration

Configure WebSockAdapter as your Phoenix WebSocket adapter in `config/config.exs`:

```elixir
config :phoenix, :json_library, Jason
config :your_app, YourAppWeb.Endpoint,
  adapter: PhoenixWebSockAdapter,
  url: [host: "localhost", port: 4000],
  http: [ip: {127, 0, 0, 1}, port: 4000],
  server: true
```

### Using with Phoenix Channels

WebSockAdapter automatically handles WebSocket connections for Phoenix.Channel functionality. No additional setup required beyond basic Phoenix configuration:

```elixir
defmodule MyAppWeb.UserSocket do
  use Phoenix.Socket

  channel "room:*", MyAppWeb.RoomChannel

  @impl true
  def connect(_params, socket, _connect_info) do
    {:ok, socket}
  end

  @impl true
  def id(_socket), do: nil
end
```

## Core Concepts

### Adapter Pattern

WebSockAdapter implements the adapter pattern to normalize WebSocket handling:

- **Transport Abstraction**: Decouples Phoenix from specific WebSocket libraries
- **Standard Interface**: Provides consistent API regardless of underlying transport
- **Pluggable Design**: Allows swapping implementations without changing Phoenix code

### WebSocket Flow

1. Client initiates WebSocket connection
2. WebSockAdapter receives connection at the adapter layer
3. Phoenix Socket layer processes the connection
4. Channel layer handles specific channel subscriptions
5. Messages flow bidirectionally through the connection

### Supervised Connections

WebSockAdapter manages WebSocket connections under Phoenix's supervision tree. Each connection:

- Runs as a supervised process
- Automatically terminates on disconnect
- Integrates with Phoenix's error handling
- Supports graceful shutdown

## Configuration

### Endpoint Configuration

Configure per-endpoint in `config/<env>.exs`:

```elixir
config :your_app, YourAppWeb.Endpoint,
  # WebSocket-specific options
  websocket_compression: false,
  websocket_ping_interval: 30000,
  websocket_timeout: 45000,

  # Standard endpoint options
  http: [ip: {127, 0, 0, 1}, port: 4000],
  https: false,
  server: true
```

### Compression Settings

Enable WebSocket compression to reduce bandwidth:

```elixir
config :your_app, YourAppWeb.Endpoint,
  websocket_compression: true
```

Note: Compression adds CPU overhead; enable only if bandwidth is constrained.

### Timeout Configuration

- **websocket_timeout**: Maximum time a WebSocket connection can remain idle (default: 45000ms)
- **websocket_ping_interval**: Interval for sending ping frames to keep connection alive (default: 30000ms)

```elixir
config :your_app, YourAppWeb.Endpoint,
  websocket_timeout: 120000,  # 2 minutes
  websocket_ping_interval: 30000  # 30 seconds
```

## Best Practices

### 1. Connection Lifecycle Management

Always implement socket connect/disconnect hooks:

```elixir
defmodule MyAppWeb.UserSocket do
  use Phoenix.Socket

  @impl true
  def connect(params, socket, connect_info) do
    # Validate user from params or connect_info
    case authenticate_user(params) do
      {:ok, user} ->
        {:ok, assign(socket, :user_id, user.id)}
      :error ->
        :error
    end
  end

  @impl true
  def id(socket) do
    "user:#{socket.assigns.user_id}"
  end
end
```

### 2. Message Handling Patterns

Use explicit pattern matching for robust message handling:

```elixir
defmodule MyAppWeb.ChatChannel do
  use Phoenix.Channel

  @impl true
  def join("chat:" <> _room_id, _payload, socket) do
    {:ok, socket}
  end

  @impl true
  def handle_in("new_msg", %{"body" => body}, socket) do
    broadcast!(socket, "new_msg", %{body: body})
    {:noreply, socket}
  end

  def handle_in("ping", _payload, socket) do
    {:reply, {:ok, %{pong: true}}, socket}
  end
end
```

### 3. Error Handling

Gracefully handle errors without crashing connections:

```elixir
defmodule MyAppWeb.ChatChannel do
  @impl true
  def handle_in("send_message", %{"text" => text}, socket) do
    case process_message(text) do
      {:ok, message} ->
        broadcast!(socket, "message", message)
        {:noreply, socket}
      {:error, reason} ->
        {:reply, {:error, %{reason: reason}}, socket}
    end
  end
end
```

### 4. Performance Considerations

- Keep message handlers fast; offload heavy work to background jobs
- Use broadcast/3 for multi-client updates; avoid individual sends
- Monitor WebSocket connection count and timeouts in production
- Set appropriate timeout values based on application needs

### 5. Client Disconnect Handling

Implement cleanup in handle_info/2:

```elixir
defmodule MyAppWeb.ChatChannel do
  @impl true
  def terminate(reason, socket) do
    IO.inspect(reason, label: "Channel terminating")
    :ok
  end
end
```

### 6. Testing WebSocket Connections

Use Phoenix.ChannelTest for testing:

```elixir
defmodule MyAppWeb.ChatChannelTest do
  use MyAppWeb.ChannelCase

  test "join and receive broadcast" do
    {:ok, _, socket} = subscribe_and_join(socket(), "chat:lobby", %{})

    ref = push(socket, "new_msg", %{"body" => "Hello"})
    assert_reply ref, :ok

    assert_broadcast "new_msg", %{"body" => "Hello"}
  end
end
```

## Common Pitfalls and Gotchas

### 1. Timeout Configuration Mismatch

If clients disconnect frequently, check timeout settings. Ping interval should be less than timeout:

```elixir
# Good
websocket_ping_interval: 30000,   # 30 seconds
websocket_timeout: 120000          # 2 minutes

# Bad
websocket_ping_interval: 120000,
websocket_timeout: 30000
```

### 2. Blocking Operations in Handlers

Never perform blocking I/O in channel handlers:

```elixir
# Bad
def handle_in("fetch_data", _, socket) do
  data = slow_database_query()  # Blocks connection
  {:reply, {:ok, data}, socket}
end

# Good
def handle_in("fetch_data", _, socket) do
  Task.start_link(fn ->
    data = slow_database_query()
    push(socket, "data_ready", data)
  end)
  {:noreply, socket}
end
```

### 3. Message Size Limits

Be aware that browsers and proxies may limit WebSocket message size. Keep payloads reasonable and compress if needed.

### 4. Stateful Socket Assigns

Socket assigns persist for connection lifetime but are cleared on reconnect:

```elixir
# Assigns survive channel messages
socket = assign(socket, :count, 0)
# But lost if client reconnects - plan accordingly
```

## Version-Specific Notes

### 0.5.9 Specifics

- Compatible with Phoenix 1.6+
- Supports Erlang/OTP 22+
- Uses plug_cowboy as default HTTP server
- WebSocket compression support via permessage-deflate
- Automatic ping/pong frame handling

---

**Version:** 0.5.9  
**Source:** https://hexdocs.pm/websock_adapter/0.5.9  
**Generated:** 2026-06-17
