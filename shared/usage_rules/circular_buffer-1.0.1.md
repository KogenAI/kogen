# circular_buffer

A fixed-size circular buffer implementation for Elixir. A circular buffer is a data structure that overwrites the oldest entries when the buffer reaches capacity, making it ideal for streaming data, metrics collection, and memory-bounded storage.

## Quick Start

### Installation

Add to `mix.exs`:

```elixir
def deps do
  [
    {:circular_buffer, "~> 1.0.1"}
  ]
end
```

Then run `mix deps.get`.

### Basic Usage

```elixir
# Create a new circular buffer with capacity of 10 elements
buffer = CircularBuffer.new(10)

# Add elements (enqueue)
buffer = CircularBuffer.insert(buffer, :item1)
buffer = CircularBuffer.insert(buffer, :item2)

# Get all items
items = CircularBuffer.to_list(buffer)

# Get buffer size
size = CircularBuffer.size(buffer)

# Check if buffer is full
full? = CircularBuffer.full?(buffer)
```

## Core Concepts

### Fixed-Size Storage

A circular buffer allocates a fixed amount of memory upfront. Once full, new insertions automatically overwrite the oldest entries. This prevents unbounded memory growth.

### Key Operations

- **`CircularBuffer.new(capacity)`** — Creates an empty buffer with fixed capacity
- **`CircularBuffer.insert(buffer, item)`** — Adds item; overwrites oldest if full
- **`CircularBuffer.to_list(buffer)`** — Returns list of current items in order
- **`CircularBuffer.size(buffer)`** — Returns number of items currently in buffer
- **`CircularBuffer.full?(buffer)`** — Checks if buffer is at capacity
- **`CircularBuffer.empty?(buffer)`** — Checks if buffer is empty

### Behavior When Full

When inserting into a full buffer, the oldest element is automatically discarded. This is the defining characteristic of circular buffers—they maintain a rolling window of the most recent N items.

```elixir
buffer = CircularBuffer.new(3)
buffer = CircularBuffer.insert(buffer, 1)
buffer = CircularBuffer.insert(buffer, 2)
buffer = CircularBuffer.insert(buffer, 3)
# buffer is full at [1, 2, 3]

buffer = CircularBuffer.insert(buffer, 4)
# buffer is now [2, 3, 4] — item 1 was overwritten
```

## Configuration

### Capacity Selection

Choose capacity based on your use case:

- **Metrics/monitoring**: Use 60-3600 for last minute/hour of data
- **Event logging**: Use 100-1000 for recent event history
- **Streaming buffers**: Use 256-8192 for throughput buffering
- **Memory-constrained systems**: Keep capacity under available RAM / item size

### Type Support

Circular buffers accept any Elixir term:

```elixir
# Store maps
buffer = CircularBuffer.new(5)
|> CircularBuffer.insert(%{id: 1, value: 100})
|> CircularBuffer.insert(%{id: 2, value: 200})

# Store tuples
buffer = CircularBuffer.new(5)
|> CircularBuffer.insert({:metric, "cpu", 85.5})

# Store any Elixir data structure
buffer = CircularBuffer.new(5)
|> CircularBuffer.insert([1, 2, 3])
```

## Best Practices

### Use Cases

1. **Metrics Collection**: Store last N measurements without manual cleanup
2. **Rolling Event Logs**: Keep recent N events for debugging
3. **Streaming Data**: Buffer incoming data with fixed memory footprint
4. **Performance Monitoring**: Track last N operation durations

### Common Patterns

#### Recent Data Window

```elixir
defmodule RequestMetrics do
  def track_request_time(metrics_buffer, duration_ms) do
    CircularBuffer.insert(metrics_buffer, duration_ms)
  end

  def average_time(metrics_buffer) do
    items = CircularBuffer.to_list(metrics_buffer)
    if Enum.empty?(items) do
      0
    else
      Enum.sum(items) / Enum.count(items)
    end
  end
end
```

#### Ensure Capacity

```elixir
# Validate buffer has minimum capacity before use
def validate_buffer(buffer, min_capacity) do
  if buffer.capacity >= min_capacity do
    {:ok, buffer}
  else
    {:error, "Buffer capacity #{buffer.capacity} < required #{min_capacity}"}
  end
end
```

### Performance Considerations

- Creation is O(capacity) — allocate buffers early in your supervisor tree
- Insertion is O(1) amortized
- Conversion to list is O(n) — cache results when possible
- Memory is fixed after creation — no GC pressure from buffer growth

### Gotchas and Edge Cases

1. **Capacity Cannot Change**: You must create a new buffer to change size. Plan capacity upfront.

2. **Insertion Order Lost When Full**: Once a buffer reaches capacity, insertion order is lost as oldest items are overwritten.

```elixir
buffer = CircularBuffer.new(2)
|> CircularBuffer.insert(:a)
|> CircularBuffer.insert(:b)
|> CircularBuffer.insert(:c)
# to_list returns [:b, :c], not [:a, :b, :c]
```

3. **No Peeking Without Conversion**: Use `to_list/1` to inspect contents; no peek-only operation exists.

4. **Immutable Operations**: Each operation returns a new buffer. Don't forget to rebind:

```elixir
# Incorrect — buffer unchanged
buffer = CircularBuffer.new(5)
CircularBuffer.insert(buffer, :item)  # Result ignored!

# Correct
buffer = CircularBuffer.new(5)
buffer = CircularBuffer.insert(buffer, :item)
```

5. **Empty Buffer Handling**: Always check `empty?/1` before assuming data exists.

### Integration with Streams

Circular buffers work well with Elixir streams for bounded historical data:

```elixir
# Keep last 100 items from a stream
stream
|> Stream.take(100)
|> Enum.reduce(CircularBuffer.new(100), fn item, buffer ->
  CircularBuffer.insert(buffer, item)
end)
```

---

**Version:** 1.0.1  
**Source:** [hexdocs.pm/circular_buffer](https://hexdocs.pm/circular_buffer/1.0.1)  
**Generated:** 2026-06-17
