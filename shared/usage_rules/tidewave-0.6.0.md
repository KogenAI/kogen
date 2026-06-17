# tidewave

Tidewave is an Elixir library for real-time data streaming and reactive programming patterns. It provides a composable, type-safe way to handle continuous data flows, state management, and side effects in concurrent applications.

## Quick Start

### Installation

Add tidewave to your `mix.exs`:

```elixir
def deps do
  [
    {:tidewave, "~> 0.6.0"}
  ]
end
```

Then run `mix deps.get`.

### Basic Usage

```elixir
defmodule MyApp.Stream do
  use Tidewave

  def start_link(_) do
    Tidewave.start_link(
      module: __MODULE__,
      name: :my_stream
    )
  end

  def init(_opts) do
    {:ok, initial_state}
  end
end
```

## Core Concepts

### Streams and Observables

Tidewave builds on reactive patterns using observables that emit values over time:

```elixir
# Create a simple observable
stream = Tidewave.Observable.from_list([1, 2, 3])

# Observe values
Tidewave.Observable.subscribe(stream, fn value ->
  IO.inspect(value)
end)
```

### Operators

Operators transform, filter, and combine streams:

```elixir
stream
|> Tidewave.Observable.map(&(&1 * 2))
|> Tidewave.Observable.filter(&(rem(&1, 2) == 0))
|> Tidewave.Observable.subscribe(fn value ->
  IO.inspect(value)
end)
```

Common operators:

- **map/2**: Transform each value
- **filter/2**: Keep only values matching a condition
- **take/2**: Take first N values
- **merge/2**: Combine multiple streams
- **debounce/2**: Suppress values emitted too closely together
- **scan/3**: Accumulate state over emissions

### Subjects

Subjects are bridges between imperative and reactive code:

```elixir
{:ok, subject} = Tidewave.Subject.create()

# Subscribe
Tidewave.Subject.subscribe(subject, fn value ->
  IO.inspect(value)
end)

# Push values
Tidewave.Subject.next(subject, :value1)
Tidewave.Subject.next(subject, :value2)
Tidewave.Subject.complete(subject)
```

### Schedulers

Control execution context for reactive operations:

```elixir
stream
|> Tidewave.Observable.observe_on(Tidewave.Scheduler.Async)
|> Tidewave.Observable.subscribe(callback)
```

Available schedulers:

- **Immediate**: Execute synchronously
- **Async**: Execute in spawned task
- **Debounce**: Debounced execution

## Configuration

### GenServer Integration

Tidewave integrates with GenServer for stateful stream management:

```elixir
defmodule MyApp.StreamServer do
  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: :stream_server)
  end

  def init(_opts) do
    {:ok, stream} = create_stream()

    {:ok, %{
      stream: stream,
      subscriptions: []
    }}
  end

  defp create_stream do
    Tidewave.Observable.interval(1000)
    |> Tidewave.Observable.map(&(&1 + 1))
  end
end
```

### Cleanup and Completion

Always handle subscriptions to prevent resource leaks:

```elixir
subscription = Tidewave.Observable.subscribe(stream, callback)

# Unsubscribe when done
Tidewave.Subscription.unsubscribe(subscription)

# Or complete the observable
Tidewave.Observable.complete(subject)
```

## Best Practices

### 1. Always Unsubscribe

Keep track of subscriptions and clean them up:

```elixir
defmodule MyApp.Subscriber do
  def start_link(stream) do
    {:ok, _pid} = Agent.start_link(fn -> [] end, name: :subs)
    subscribe_to_stream(stream)
  end

  defp subscribe_to_stream(stream) do
    sub = Tidewave.Observable.subscribe(stream, fn value ->
      handle_value(value)
    end)

    Agent.update(:subs, &[sub | &1])
  end

  def cleanup do
    Agent.get(:subs, &Function.identity/1)
    |> Enum.each(&Tidewave.Subscription.unsubscribe/1)
  end
end
```

### 2. Use Operators to Compose Logic

Avoid imperative handling in callbacks; use operators:

```elixir
# Good: Declarative composition
stream
|> Tidewave.Observable.filter(&is_valid?/1)
|> Tidewave.Observable.map(&transform/1)
|> Tidewave.Observable.debounce(300)
|> Tidewave.Observable.subscribe(callback)

# Avoid: Complex callback logic
stream
|> Tidewave.Observable.subscribe(fn value ->
  if is_valid?(value) do
    transformed = transform(value)
    # complex logic...
  end
end)
```

### 3. Error Handling

Implement error callbacks to handle stream failures:

```elixir
Tidewave.Observable.subscribe(
  stream,
  fn value -> handle_value(value) end,
  fn error ->
    IO.inspect({"Stream error", error})
    # Recover or cleanup
  end,
  fn ->
    # On completion
  end
)
```

### 4. Memory and Resource Management

Be aware of backpressure and buffering:

```elixir
# Use buffer_size for long-running operations
stream
|> Tidewave.Observable.buffer_size(100)
|> Tidewave.Observable.subscribe(callback)

# Use debounce to reduce frequency
stream
|> Tidewave.Observable.debounce(500)
|> Tidewave.Observable.subscribe(callback)
```

### 5. Testing Streams

Use test utilities to verify stream behavior:

```elixir
defmodule MyApp.StreamTest do
  use ExUnit.Case

  test "stream transforms values correctly" do
    stream = Tidewave.Observable.from_list([1, 2, 3])

    result = stream
    |> Tidewave.Observable.map(&(&1 * 2))
    |> Tidewave.Observable.to_list()

    assert result == [2, 4, 6]
  end
end
```

## Common Gotchas

1. **Synchronous vs. Asynchronous**: By default, subscriptions execute synchronously. Use schedulers to change execution context.

2. **Subscription Timing**: Subscribing after values are emitted may miss them. Use ReplaySubject if needed.

3. **Shared vs. Independent Subscriptions**: Each subscription creates an independent stream execution. Use `share()` to share execution.

4. **Memory Leaks**: Unsubscribe in process termination or cleanup handlers to prevent accumulating subscriptions.

5. **Error Propagation**: Errors in callbacks don't automatically propagate; provide error handlers explicitly.

---

**Version:** 0.6.0  
**Source:** https://hexdocs.pm/tidewave/0.6.0  
**Generated:** 2026-06-17
