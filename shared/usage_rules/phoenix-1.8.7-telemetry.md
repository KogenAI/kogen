# Phoenix - Telemetry & Monitoring

## Telemetry Overview

Telemetry enables event-driven observability through the `:telemetry` library. Applications emit named events at key lifecycle moments, which reporters capture, aggregate, and export to monitoring backends. This decouples instrumentation from the monitoring system.

## Core Components

### Events

Each telemetry event consists of three parts:

1. **Name** — Unique identifier as atom list, e.g., `[:phoenix, :endpoint, :stop]`
2. **Measurements** — Numeric values in native time units (microseconds)
3. **Metadata** — Key-value contextual data for filtering and tagging

Example emission:

```elixir
:telemetry.execute([:my_app, :user, :created], %{time: 1234}, %{user_id: user.id})
```

### Metrics

Metrics aggregate telemetry events over time, providing a summary view of system behavior. Common metric types:

- **Counter** — Cumulative count of events
- **Distribution** — Value distribution (histogram)
- **Summary** — Statistics (mean, percentiles)
- **Last Value** — Most recent value
- **Gauge** — Current point-in-time value

## Phoenix Telemetry Supervisor

New applications include a telemetry supervisor module:

```elixir
defmodule MyApp.Telemetry do
  use Supervisor

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  def init(_arg) do
    children = [
      {:telemetry_poller, child_spec(telemetry_poller_measurements())},
      {MyApp.Metrics.PrometheusExporter, []}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp telemetry_poller_measurements do
    [
      memory: [unit: {:byte, :kilobyte}],
      total_run_queue_lengths: [unit: :non_negative_integer]
    ]
  end

  def metrics do
    [
      counter("http.requests.total"),
      distribution("http.request.duration",
        unit: {:native, :millisecond}
      ),
      last_value("vm.memory.total", unit: {:byte, :kilobyte}),
    ]
  end
end
```

## Built-in Phoenix Events

Phoenix automatically emits events at key points:

### HTTP Request Events

```
[:phoenix, :endpoint, :start]
  measurements: %{time: System.monotonic_time()}
  metadata: %{conn: %Plug.Conn{}, ...}

[:phoenix, :endpoint, :stop]
  measurements: %{duration: elapsed_time}
  metadata: %{status: 200, method: "GET", path: "/", ...}
```

### Router Events

```
[:phoenix, :router_dispatch, :start]
  measurements: %{time: System.monotonic_time()}
  metadata: %{plug: MyApp.Router, ...}

[:phoenix, :router_dispatch, :stop]
  measurements: %{duration: elapsed_time}
  metadata: %{status: 200, plug: MyApp.Router, route: "/users/:id", ...}
```

### Database Events

Ecto emits events during queries:

```
[:ecto, :repo, :query]
  measurements: %{total_time: µs, decode_time: µs, query_time: µs, queue_time: µs}
  metadata: %{repo: MyApp.Repo, source: "users", query: "SELECT ...", ...}
```

## Custom Instrumentation

Emit custom events for application-specific monitoring:

```elixir
defmodule MyApp.Accounts do
  def create_user(attrs) do
    start_time = System.monotonic_time()

    result = %User{}
    |> User.changeset(attrs)
    |> Repo.insert()

    duration = System.monotonic_time() - start_time

    case result do
      {:ok, user} ->
        :telemetry.execute(
          [:my_app, :user, :created],
          %{duration: duration},
          %{user_id: user.id}
        )
        {:ok, user}

      {:error, changeset} ->
        :telemetry.execute(
          [:my_app, :user, :creation_failed],
          %{duration: duration},
          %{errors: changeset.errors}
        )
        {:error, changeset}
    end
  end
end
```

## Metric Collection

### Defining Metrics

Create a metrics module:

```elixir
defmodule MyApp.Metrics do
  def metrics do
    [
      # HTTP metrics
      counter("http.requests.total",
        description: "Total HTTP requests",
        tags: [:method, :route, :status]
      ),

      distribution("http.request.duration",
        description: "HTTP request duration",
        unit: {:native, :millisecond},
        tags: [:method, :route]
      ),

      # Database metrics
      counter("db.query.total",
        description: "Total database queries",
        tags: [:repo, :source]
      ),

      distribution("db.query.duration",
        description: "Database query duration",
        unit: {:native, :millisecond}
      ),

      # VM metrics
      last_value("vm.memory.total",
        unit: {:byte, :megabyte}
      ),

      last_value("vm.total_run_queue_lengths"),
    ]
  end
end
```

### Event Handlers

Listen to events and extract metrics:

```elixir
defmodule MyApp.MetricsHandler do
  def attach_handlers do
    :telemetry.attach(
      "http_request_duration",
      [:phoenix, :endpoint, :stop],
      &handle_http_stop/4,
      nil
    )

    :telemetry.attach(
      "db_query_duration",
      [:ecto, :repo, :query],
      &handle_db_query/4,
      nil
    )
  end

  def handle_http_stop(_event, measurements, metadata, _config) do
    duration_ms = measurements.duration / 1_000_000
    status = metadata.status

    MyApp.Metrics.observe("http.request.duration", duration_ms, %{
      method: metadata.method,
      status: status,
      route: extract_route(metadata)
    })
  end

  def handle_db_query(_event, measurements, metadata, _config) do
    query_time_ms = measurements.query_time / 1_000_000

    MyApp.Metrics.observe("db.query.duration", query_time_ms, %{
      repo: metadata.repo,
      source: metadata.source
    })
  end

  defp extract_route(metadata) do
    case metadata do
      %{route: route} -> route
      _ -> "unknown"
    end
  end
end
```

## Integration with Prometheus

Export metrics to Prometheus:

```elixir
# mix.exs
defp deps do
  [
    {:prometheus_ex, "~> 3.0"},
    {:prometheus_plugs, "~> 1.1"}
  ]
end

# lib/my_app/prometheus.ex
defmodule MyApp.PrometheusExporter do
  def start_link(_opts) do
    {:ok, _} = :telemetry.attach_many(
      "prometheus",
      metrics_events(),
      &MyApp.MetricsHandler.prometheus_handler/4,
      nil
    )

    {:ok, self()}
  end

  defp metrics_events do
    [
      [:phoenix, :endpoint, :stop],
      [:ecto, :repo, :query]
    ]
  end
end
```

Expose metrics endpoint:

```elixir
# lib/my_app_web/router.ex
scope "/metrics" do
  get "/", Plug.Telemetry.Prometheus, []
end
```

Access Prometheus metrics at `/metrics`.

---

[← Back to main](phoenix-1.8.7.md)
**Version:** 1.8.7
