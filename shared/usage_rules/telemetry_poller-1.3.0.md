# telemetry_poller

Periodic system metrics collection and dispatch via the Telemetry framework. telemetry_poller automatically monitors VM metrics (memory, scheduler queue lengths, system counts) and supports custom measurement implementations.

## Quick Start

### Installation

Add to your `mix.exs`:

```elixir
defp deps do
  [
    {:telemetry_poller, "~> 1.3"}
  ]
end
```

### Basic Setup in Supervision Tree

```elixir
defmodule MyApp.Application do
  use Application

  def start(_type, _args) do
    children = [
      {TelemetryPoller,
        name: :default_poller,
        period: 5000,  # milliseconds
        measurements: [
          {:memory, []},
          {:total_run_queue_lengths, []},
          {:system_counts, []}
        ]
      }
    ]

    opts = [strategy: :one_for_one, name: MyApp.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
```

## Core Concepts

### Built-in Measurements

The poller provides four default VM measurements:

- **`memory`** — Total and process memory plus all `erlang:memory/0` data, emitted to `[vm, memory]` event
- **`total_run_queue_lengths`** — CPU and IO scheduler queue lengths with total counts, emitted to `[vm, total_run_queue_lengths]` event
- **`system_counts`** — Process, atom, and port counts with limits, emitted to `[vm, system_counts]` event
- **`persistent_term`** — Term count and memory usage, emitted to `[vm, persistent_term]` event

### Custom Measurements

Implement custom measurements via module-function-arguments (MFA) tuples that execute telemetry events:

```elixir
defmodule MyApp.CustomMetrics do
  def collect_sessions(_) do
    count = Redis.session_count()
    :telemetry.execute([:custom, :sessions], %{count: count}, %{})
  end
end

# In supervision tree:
{TelemetryPoller,
  name: :custom_poller,
  period: 10000,
  measurements: [
    {MyApp.CustomMetrics, :collect_sessions, []}
  ]
}
```

### Poller Instance Management

Create multiple pollers for different monitoring strategies:

```elixir
children = [
  # VM metrics every 5 seconds
  {TelemetryPoller,
    name: :vm_poller,
    period: 5000,
    measurements: [:memory, :total_run_queue_lengths, :system_counts]
  },
  # Custom app metrics every 10 seconds
  {TelemetryPoller,
    name: :app_poller,
    period: 10000,
    measurements: [
      {MyApp.CustomMetrics, :collect_sessions, []},
      {MyApp.CustomMetrics, :collect_queue_depth, []}
    ]
  }
]
```

## Configuration

### Options

- **`name`** (required) — Atom or registered name for the poller instance
- **`period`** (optional, default: 5000) — Polling interval in milliseconds; must be positive integer
- **`init_delay`** (optional, default: 0) — Delay in milliseconds before first collection; useful for staggering multiple pollers
- **`measurements`** (optional, default: all VM measurements) — List of measurement specifications to collect

### Measurement Specifications

```elixir
measurements: [
  # Built-in VM measurements
  :memory,
  :total_run_queue_lengths,
  :system_counts,
  :persistent_term,

  # Custom function MFA
  {MyApp.Metrics, :collect_db_connections, []},
  {MyApp.Metrics, :collect_cache_stats, [key: "cache:default"]},

  # Process info measurement with filters
  {:process_info, [:message_queue_len, :memory]}
]
```

### Staggered Polling Example

```elixir
children = [
  {TelemetryPoller,
    name: :poller_1,
    period: 5000,
    init_delay: 0,
    measurements: [:memory]
  },
  {TelemetryPoller,
    name: :poller_2,
    period: 5000,
    init_delay: 2000,  # Start 2 seconds after poller_1
    measurements: [:total_run_queue_lengths]
  }
]
```

## Best Practices

### Performance Considerations

- **Polling Period**: Default 5 seconds balances responsiveness and overhead. Increase for lower-frequency monitoring; decrease cautiously to avoid excessive system load
- **Stagger Startups**: Use `init_delay` to distribute polling across multiple pollers and prevent synchronized measurement spikes
- **Selective Measurements**: Only enable measurements you actually use; omitting unused metrics reduces overhead

### Custom Measurement Implementation

```elixir
# ✅ GOOD: Quick, non-blocking measurement
defmodule MyApp.Metrics do
  def collect_cache_hit_rate(_) do
    {:ok, hits} = Redis.get("cache:hits")
    {:ok, total} = Redis.get("cache:total")
    rate = if total > 0, do: hits / total, else: 0
    :telemetry.execute([:app, :cache_hit_rate], %{rate: rate}, %{})
  end
end

# ❌ BAD: Slow/blocking measurement will delay poller
defmodule BadMetrics do
  def slow_query(_) do
    # Heavy database query blocks poller
    Repo.all(from u in User, select: count(u.id))
    :telemetry.execute([:db, :user_count], %{}, %{})
  end
end
```

### Event Listener Setup

Attach listeners to poller events in your application startup:

```elixir
:telemetry.attach(
  "my_app_poller_handler",
  [:vm, :memory],
  &MyApp.TelemetryHandler.handle_memory/4,
  nil
)

defmodule MyApp.TelemetryHandler do
  def handle_memory([:vm, :memory], measurements, _metadata, _config) do
    Logger.info("Memory: #{measurements.total} bytes")
  end
end
```

### Multiple Pollers Pattern

Use separate pollers for different monitoring concerns:

```elixir
children = [
  # Frequent system metrics
  {TelemetryPoller,
    name: :system_poller,
    period: 5000,
    measurements: [:memory, :total_run_queue_lengths]
  },
  # Less frequent application metrics
  {TelemetryPoller,
    name: :app_poller,
    period: 30000,
    measurements: [
      {MyApp.Metrics, :collect_database_connections, []},
      {MyApp.Metrics, :collect_external_service_health, []}
    ]
  }
]
```

### Integration with Telemetry Metrics

Combine with telemetry_metrics for centralized metric aggregation:

```elixir
# In your Telemetry supervisor
telemetry_metrics: [
  Telemetry.Metrics.Memory.total(unit: :byte),
  Telemetry.Metrics.Summary("vm.total_run_queue_lengths.cpu"),
  Telemetry.Metrics.LastValue("app.cache_hit_rate")
]
```

---

**Version:** 1.3.0
**Source:** [hexdocs.pm/telemetry_poller](https://hexdocs.pm/telemetry_poller/)
**Generated:** 2025-10-28
