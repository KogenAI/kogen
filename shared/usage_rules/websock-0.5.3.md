# websock

WebSock is a lightweight Elixir library for WebSocket handling that provides a simple, flexible API for building real-time applications. It abstracts away the complexity of WebSocket protocol handling and integrates seamlessly with Phoenix and standalone Elixir applications.

## Quick Start

### Installation

Add to `mix.exs`:

```elixir
def deps do
  [
    {:websock, "~> 0.5.3"}
  ]
end
```

### Basic Server Setup

```elixir
defmodule MyApp.WebSocketHandler do
  @behaviour WebSock.Handle

  def init(state) do
    {:ok, state}
  end

  def handle_in({"message", [opcode: :text]}, state) do
    {:reply, :ok, {:text, "Echo: message"}, state}
  end

  def handle_info({:custom, msg}, state) do
    {:reply, {:text, msg}, state}
  end

  def terminate(reason, state) do
    :ok
  end
end
```

### Phoenix Integration

Plug WebSock into your Phoenix router:

```elixir
scope "/ws" do
  forward "/socket", WebSock.SocketHandler, {MyApp.WebSocketHandler, []}
end
```

## Core Concepts

### Handler Behaviour

Implement the `WebSock.Handle` behaviour with five required callbacks:

- **`init(state)`** - Initialize connection state, return `{:ok, state}`
- **`handle_in(message, state)`** - Process incoming messages
- **`handle_info(message, state)`** - Handle internal process messages
- **`handle_control(frame, state)`** - Handle control frames (ping, pong, close)
- **`terminate(reason, state)`** - Clean up on disconnect

### Message Format

Incoming messages are tuples: `{payload, options}`

```elixir
{text_data, [opcode: :text]}      # Text frame
{binary_data, [opcode: :binary]}  # Binary frame
{_, [opcode: :ping]}              # Ping control frame
{_, [opcode: :pong]}              # Pong control frame
{_, [opcode: :close, code: code]} # Close frame
```

### Response Replies

Return from handlers using:

```elixir
{:reply, :ok, {opcode, data}, state}           # Send message and continue
{:reply, {:ok, responses}, state}              # Multiple messages
{:ok, state}                                   # No reply, continue
{:stop, reason, state}                         # Close connection gracefully
```

## Configuration

### Handler Options

Pass options in the forward directive:

```elixir
forward "/socket", WebSock.SocketHandler,
  {MyApp.WebSocketHandler, [initial_state: %{user_id: nil}]}
```

### Compression

WebSock 0.5.3 supports permessage-deflate compression. Enable via client negotiation:

```elixir
# Client-side (typically JavaScript)
const ws = new WebSocket('ws://...', ['permessage-deflate']);
```

### Timeouts

Configure at the socket level:

```elixir
# In endpoint.ex
config :my_app, MyApp.Endpoint,
  socket_options: [
    timeout: 45_000  # milliseconds
  ]
```

## Best Practices

### State Management

- Keep state simple and serializable; store heavy data externally
- Use Phoenix Presence for multi-client state
- Clean up resources in `terminate/2` callback

```elixir
def terminate(:normal, %{user_id: user_id}) do
  MyApp.Presence.untrack(:client, user_id)
  :ok
end
```

### Error Handling

- Validate all incoming messages
- Return `{:stop, :normal, state}` for clean shutdown
- Handle network errors gracefully; reconnection is client responsibility

```elixir
def handle_in({data, _opts}, state) do
  case parse_message(data) do
    {:ok, msg} -> process(msg, state)
    :error -> {:reply, :ok, {:text, "Invalid message"}, state}
  end
end
```

### Broadcasting

Use Phoenix PubSub to broadcast to multiple clients:

```elixir
def handle_info({:broadcast, msg}, state) do
  {:reply, {:text, msg}, state}
end

# Broadcast from elsewhere
Phoenix.PubSub.broadcast(:pubsub, "topic", {:broadcast, "message"})

# Subscribe in init
def init(state) do
  Phoenix.PubSub.subscribe(:pubsub, "topic")
  {:ok, state}
end
```

### Connection Lifecycle

```elixir
def init(state) do
  send(self(), :ready)
  {:ok, state}
end

def handle_info(:ready, state) do
  {:reply, {:text, "Connected"}, state}
end

def handle_control({_, [opcode: :ping]}, state) do
  {:reply, :ok, {:pong, ""}, state}
end

def handle_control({_, [opcode: :close]}, state) do
  {:stop, :normal, state}
end
```

## Common Patterns

### Authentication Wrapper

```elixir
defmodule MyApp.AuthenticatedSocket do
  @behaviour WebSock.Handle

  def init({handler, initial_state}) do
    {:ok, %{handler: handler, state: initial_state}}
  end

  def handle_in({data, opts}, context) do
    apply(context.handler, :handle_in, [{data, opts}, context.state])
    |> update_context(context)
  end

  defp update_context({:reply, :ok, response, new_state}, context) do
    {:reply, :ok, response, %{context | state: new_state}}
  end
end
```

### JSON Message Parsing

```elixir
def handle_in({json, _}, state) do
  case Jason.decode(json) do
    {:ok, %{"type" => "ping"}} ->
      {:reply, :ok, {:text, Jason.encode!(%{type: "pong"})}, state}
    {:ok, msg} ->
      process_message(msg, state)
    :error ->
      {:ok, state}
  end
end
```

## Version-Specific Notes

**0.5.3 Changes:**

- Stable handler behaviour API
- Improved control frame handling
- Better compliance with RFC 6455
- No breaking changes from 0.5.x

**Migration from older versions:**

- Ensure all handler callbacks are implemented
- Update message tuple destructuring for new format

---

**Version:** 0.5.3
**Source:** https://hexdocs.pm/websock
**Generated:** 2026-06-17
