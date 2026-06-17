# telemetry

Telemetry is a lightweight metrics and event collection library for Elixir and Erlang applications. It enables applications to emit structured events that can be observed by multiple handlers, supporting observability, monitoring, and analytics use cases without coupling the event emitter to observers.

## Quick Start

### Installation

Add telemetry to your `mix.exs`:

```elixir
def deps do
  [
    {:telemetry, "~> 1.4"}
  ]
end
```

### Basic Usage

Emit a telemetry event:

```elixir
:telemetry.execute([:myapp, :request], %{latency: 250}, %{status: 200})
```

Attach a handler to observe events:

```elixir
:telemetry.attach(
  "my_handler",
  [:myapp, :request],
  &MyApp.Telemetry.handle_request/4,
  nil
)

def handle_request(event_name, measurements, metadata, config) do
  IO.inspect({event_name, measurements, metadata})
end
```

Detach handler when done:

```elixir
:telemetry.detach("my_handler")
```

## Core Concepts

### Event Structure

**Event name**: A list of atoms identifying the event (e.g., `[:myapp, :request]`)

**Measurements**: A map of numeric values recorded at event time (e.g., `%{latency: 250, memory: 1024}`)

**Metadata**: A map of contextual information (e.g., `%{status: 200, user_id: 1}`)

**Handler context**: Optional configuration passed when attaching, available to the handler

### Event Hierarchy

Event names form a hierarchy. Handlers can attach to parent events and receive all child events:

```elixir
# Attach to parent event
:telemetry.attach("parent", [:myapp], &handler/4, nil)

# This will trigger the handler
:telemetry.execute([:myapp, :request], %{}, %{})
:telemetry.execute([:myapp, :database, :query], %{}, %{})
```

### Handler Signature

All handlers receive four arguments:

```elixir
def my_handler(event_name, measurements, metadata, config) do
  # event_name: list of atoms
  # measurements: map of numeric values
  # metadata: map of contextual data
  # config: value passed during attach
end
```

Handlers should not raise exceptions. If a handler crashes, telemetry stops executing remaining handlers for that event.

### Multiple Handlers

Multiple handlers can be attached to the same event. They execute in order:

```elixir
:telemetry.attach("handler1", [:myapp, :event], &h1/4, nil)
:telemetry.attach("handler2", [:myapp, :event], &h2/4, nil)

# Both h1 and h2 execute when event is emitted
:telemetry.execute([:myapp, :event], %{}, %{})
```

## Configuration

### Application Startup Setup

Typically attach handlers during application startup in a module:

```elixir
defmodule MyApp.Telemetry do
  def attach_handlers do
    :telemetry.attach(
      "myapp-logger",
      [:myapp, :request],
      &log_request/4,
      nil
    )

    :telemetry.attach(
      "myapp-metrics",
      [:myapp, :database, :query],
      &record_query_metrics/4,
      %{type: :metrics}
    )
  end

  def log_request(event, measurements, metadata, _config) do
    Logger.info("#{inspect(event)}: #{measurements.latency}ms")
  end

  def record_query_metrics(event, measurements, metadata, config) do
    # Send to monitoring system
  end
end
```

Register in your application's start sequence:

```elixir
defmodule MyApp.Application do
  use Application

  def start(_type, _args) do
    children = [
      # ... other children
    ]

    opts = [strategy: :one_for_one, name: MyApp.Supervisor]
    Supervisor.start_link(children, opts)
    |> tap(fn _ -> MyApp.Telemetry.attach_handlers() end)
  end
end
```

### Pattern-Based Attachment

Attach to events matching a pattern using wildcards in the event name:

```elixir
# Attach to all events under :myapp namespace
:telemetry.attach_many(
  "myapp-all",
  [[:myapp]],
  &universal_handler/4,
  nil
)

def universal_handler([:myapp | rest] = event, measurements, metadata, _config) do
  IO.inspect({event, measurements, metadata})
end
```

### Handler Context

Pass configuration to handlers during attachment:

```elixir
:telemetry.attach(
  "custom_handler",
  [:myapp, :request],
  &handle_with_config/4,
  %{threshold: 500, action: :alert}
)

def handle_with_config(event, measurements, metadata, config) do
  if measurements.latency > config.threshold do
    send_alert(config.action)
  end
end
```

## Best Practices

### Event Naming Conventions

- Use hierarchical names: `[:app, :feature, :operation]`
- Keep event names consistent and documented
- Use atoms (not strings) in event names for performance

### Emission Guidelines

Emit events at logical boundaries:

```elixir
# In a request handler
def handle_request(conn, _opts) do
  start = System.monotonic_time()

  result = process_request(conn)

  duration = System.monotonic_time() - start

  :telemetry.execute(
    [:myapp, :http, :request],
    %{duration: duration},
    %{method: conn.method, path: conn.request_path, status: conn.status}
  )

  result
end
```

### Handler Safety

- Keep handlers fast and non-blocking
- Avoid raising exceptions in handlers
- Log handler errors separately if needed
- Use try/catch within handlers if exceptions are possible

### Memory and Performance

- Avoid storing large amounts of data in metadata
- Metadata is copied to each handler, so keep it minimal
- Measurements should be numeric only (no maps/lists)
- Handler context (config) is shared and not copied

### Documentation

Document your application's telemetry events:

```elixir
@doc """
Emitted when a database query completes.

Measurements:
  - `:duration` - query duration in microseconds

Metadata:
  - `:query` - the SQL query string
  - `:status` - :ok or :error
"""
def emit_query_event, do: :telemetry.execute([:myapp, :db, :query], ...)
```

### Integration with Monitoring Tools

Telemetry is the standard event substrate for Elixir observability libraries:

- **Prometheus**: Use `:prometheus_ex` to convert telemetry events to metrics
- **Datadog**: Send events through custom handlers
- **Grafana Loki**: Log handler can send structured logs
- **Honeycomb**: Attach handlers that send traces

### Testing

Mock telemetry in tests:

```elixir
test "emits telemetry event" do
  handler_called = self()

  :telemetry.attach_many(
    "test_handler",
    [[:myapp, :event]],
    fn event, measurements, metadata, _ ->
      send(handler_called, {:event, event, measurements})
    end,
    nil
  )

  trigger_event()

  assert_receive {:event, [:myapp, :event], %{value: _}}

  :telemetry.detach("test_handler")
end
```

---

**Version:** 1.4.2
**Source:** hexdocs.pm/telemetry
**Generated:** 2026-06-17
