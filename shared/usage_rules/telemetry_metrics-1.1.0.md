# telemetry_metrics

Telemetry.Metrics provides a common interface for defining metrics based on `:telemetry` events. It aggregates telemetry events into measurable views of system behavior, offering a standardized approach to collecting and reporting application metrics.

## Quick Start

### Installation

```elixir
defp deps do
  [
    {:telemetry_metrics, "~> 1.1"}
  ]
end
```

### Basic Metric Definition

```elixir
# Define metrics using one of five types
[
  counter("http.request.total"),
  sum("http.request.duration", unit: {:native, :millisecond}),
  last_value("vm.memory.total"),
  summary("database.query.time"),
  distribution("request.size")
]
```

## Core Concepts

### Five Metric Types

**Counter** — Counts total emitted events

- Increments on each event emission
- Useful for request counts, error totals
- `counter("http.request.total")`

**Sum** — Aggregates selected measurements over time

- Sums measurement values from events
- Useful for total bytes transferred, cumulative latency
- `sum("http.request.bytes_sent")`

**Last Value** — Records the most recent measurement

- Captures the latest measurement only
- Useful for gauge-like metrics (memory, connections)
- `last_value("vm.memory.total")`

**Summary** — Calculates statistics across measurements

- Computes min, max, mean, percentiles
- Useful for understanding distribution (p50, p99)
- `summary("http.request.duration")`

**Distribution** — Builds histograms of measurement values

- Groups measurements into buckets
- Useful for histogram-based analysis
- `distribution("response.size")`

### Metric Names

Metric names can be strings or atom lists:

- String: `"http.request.stop.duration"`
- Atoms: `[:http, :request, :stop, :duration]`

The system automatically infers:

- **Event name**: All segments except the last (e.g., `[:http, :request, :stop]`)
- **Measurement**: The final segment (e.g., `:duration`)

### Tags and Breakdown

Tags enable breaking down metrics by dimensions:

```elixir
summary("http.request.duration",
  tags: [:method, :status],
  tag_values: fn %{"method" => m, "status" => s} ->
    %{method: m, status: s}
  end
)
```

## Configuration

### Common Options

**`:event_name`** — Explicitly specify source event

```elixir
counter("requests", event_name: [:http, :request, :stop])
```

**`:measurement`** — Source for aggregation

```elixir
# Extract single value
sum("duration", measurement: :duration)

# Unary function
sum("duration_ms", measurement: fn m -> m.duration end)

# Binary function (e.g., difference)
sum("latency", measurement: fn start, end -> end - start end)
```

**`:keep` / `:drop`** — Conditional recording (mutually exclusive)

```elixir
summary("request.duration",
  keep: fn %{"status" => s} -> s < 400 end
)

distribution("error.response.time",
  drop: fn %{"status" => s} -> s < 400 end
)
```

**`:unit`** — Specify measurement units with conversion

```elixir
# Time conversions: :native, :second, :millisecond, :microsecond, :nanosecond
summary("request.time", unit: {:native, :millisecond})

# Byte conversions: :byte, :kilobyte, :megabyte
sum("network.bytes", unit: {:byte, :kilobyte})
```

**`:description`** — Human-readable documentation

```elixir
counter("http.request.total", description: "Total HTTP requests processed")
```

**`:reporter_options`** — Reporter-specific configuration

```elixir
summary("db.query.time",
  reporter_options: [bucket_boundaries: [10, 50, 100, 500]]
)
```

## Best Practices

### Metric Design

1. **Name consistently**: Use dot-separated, lowercase names (e.g., `http.request.duration`)
2. **Include units in names or configuration**: Be explicit about measurement units
3. **Use appropriate types**: Choose counter for counts, sum for aggregation, last_value for gauges
4. **Tag strategically**: Add tags for important breakdowns (method, status, resource type)
5. **Filter appropriately**: Use `:keep` or `:drop` to avoid recording irrelevant events

### Event Emission

```elixir
# Emit events for metrics to aggregate
:telemetry.execute(
  [:http, :request, :stop],
  %{duration: elapsed_time},
  %{method: "GET", status: 200, path: "/api/users"}
)
```

### Reporter Integration

- Reporters consume metric definitions and subscribe to events
- Common reporters: StatsD, Prometheus, time-series databases
- Official reporters available on BEAM Telemetry GitHub organization
- Example: `TelemetryMetricsPrometheus`, `TelemetryMetricsStatsD`

### Performance Considerations

1. **Lazy evaluation**: Avoid expensive computations in `:keep`, `:drop`, `:tag_values`
2. **Cardinality**: Be cautious with high-cardinality tags (user IDs, request IDs)
3. **Event frequency**: Heavy event emission can impact performance
4. **Reporter buffering**: Batch metric publishes to reduce overhead

### Common Patterns

**Request metrics across lifecycle**:

```elixir
[
  counter("http.request.total"),
  summary("http.request.duration", unit: {:native, :millisecond}),
  counter("http.request.errors", drop: fn %{"error" => nil} -> true end)
]
```

**Database performance monitoring**:

```elixir
[
  summary("db.query.time", tags: [:query_type]),
  counter("db.query.total", tags: [:query_type]),
  distribution("db.connection.wait_time")
]
```

**System resource tracking**:

```elixir
[
  last_value("vm.memory.total", description: "Total VM memory"),
  last_value("vm.process.count", description: "Active processes"),
  counter("vm.garbage_collections", description: "GC cycles")
]
```

---

**Version:** 1.1.0
**Source:** [hexdocs.pm/telemetry_metrics](https://hexdocs.pm/telemetry_metrics/)
**Generated:** 2025-10-28
