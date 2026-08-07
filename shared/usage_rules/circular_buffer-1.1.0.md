# circular_buffer

CircularBuffer is an Elixir library that provides a fixed-size circular buffer implementation. It uses Okasaki queues (similar to Erlang's `:queue` module) with additional optimizations for a reduced set of operations. Circular buffers are ideal for bounded collections that automatically discard older entries as new data arrives.

## Quick Start

### Installation

Add to `mix.exs`:

```elixir
def deps do
  [
    {:circular_buffer, "~> 1.1.0"}
  ]
end
```

Then run `mix deps.get`.

### Basic Usage

Create a new circular buffer with fixed capacity:

```elixir
cb = CircularBuffer.new(10)
```

Insert elements (automatically discards oldest when buffer is full):

```elixir
cb = CircularBuffer.new(3)
  |> CircularBuffer.insert(1)
  |> CircularBuffer.insert(2)
  |> CircularBuffer.insert(3)
  |> CircularBuffer.insert(4)  # Discards 1, keeps [2, 3, 4]
```

Query the buffer:

```elixir
CircularBuffer.newest(cb)   # Returns: 4
CircularBuffer.oldest(cb)   # Returns: 2
CircularBuffer.to_list(cb)  # Returns: [2, 3, 4]
```

## Core Concepts

### Fixed-Size Design

Circular buffers maintain a maximum capacity specified at creation. Once full, inserting a new element automatically removes the oldest element. This prevents unbounded memory growth.

### Protocol Support

CircularBuffer implements `Enumerable` and `Collectable` protocols, enabling standard Elixir operations:

```elixir
# Using Collectable with Enum.into/2
cb = Enum.into([1, 2, 3, 4], CircularBuffer.new(3))

# Using Enumerable
Enum.map(cb, fn x -> x * 2 end)      # Returns [4, 6, 8]
Enum.filter(cb, fn x -> x > 2 end)   # Returns [3, 4]
```

### Element Ordering

Elements are retrieved from oldest to newest via `to_list/1`:

```elixir
cb = Enum.into([1, 2, 3], CircularBuffer.new(5))
CircularBuffer.to_list(cb)  # Returns: [1, 2, 3] (oldest to newest)
```

## Configuration

### Buffer Creation

```elixir
# Create empty buffer with capacity 10
buffer = CircularBuffer.new(10)

# Create buffer with initial capacity and custom options (if supported)
buffer = CircularBuffer.new(10, opts)
```

### Core Functions

- `new/1` – Create buffer with specified capacity
- `new/2` – Create buffer with capacity and options
- `insert/2` – Add element to buffer
- `empty?/1` – Check if buffer contains no elements
- `newest/1` – Get most recently inserted element
- `oldest/1` – Get least recently inserted element
- `to_list/1` – Convert to list (oldest to newest)
- `max_size/1` – Query buffer capacity

## Best Practices

### Use Cases

Use CircularBuffer when you need:

- **Bounded collections** that prevent memory leaks
- **Sliding window data** (recent N items)
- **Logging buffers** for keeping recent logs
- **Sensor data streams** with memory constraints
- **Event history** with limited retention

### Implementation Patterns

```elixir
# Bounded event log (keep last 100 events)
defmodule EventLog do
  def new, do: CircularBuffer.new(100)

  def add_event(log, event) do
    CircularBuffer.insert(log, event)
  end

  def recent_events(log) do
    CircularBuffer.to_list(log)
  end
end

# Sliding window statistics
defmodule WindowStats do
  def window(size), do: CircularBuffer.new(size)

  def add_value(window, value) do
    CircularBuffer.insert(window, value)
  end

  def average(window) do
    list = CircularBuffer.to_list(window)
    Enum.sum(list) / length(list)
  end
end
```

### Performance Considerations

- Okasaki queue implementation provides O(1) insertion
- Protocol implementations enable efficient use with `Enum` functions
- Fixed-size design prevents memory bloat in long-running processes

---

**Version:** 1.1.0
**Source:** [hexdocs.pm/circular_buffer](https://hexdocs.pm/circular_buffer/1.1.0)
**Generated:** 2026-08-07
