# oban - Observability & Telemetry

## Telemetry Event Categories

Oban emits structured telemetry events across multiple system components for comprehensive observability and metrics collection.

## Job Lifecycle Events

**Job Start** — `[:oban, :job, :start]` fires when a job is fetched and execution begins:

```elixir
:telemetry.attach_handler(
  "oban-job-start",
  [:oban, :job, :start],
  fn _event_name, _measurements, %{job: job, conf: conf}, _handler_config ->
    Logger.info("Starting #{job.worker} job #{job.id}")
  end,
  nil
)
```

Measurements: none (start event)
Metadata: `:conf` (Oban.Config), `:job` (Oban.Job)

**Job Stop** — `[:oban, :job, :stop]` fires on successful completion:

```elixir
:telemetry.attach_handler(
  "oban-job-stop",
  [:oban, :job, :stop],
  fn _event_name, measurements, metadata, _handler_config ->
    IO.inspect(measurements)  # %{duration: ..., memory: ..., queue_time: ..., reductions: ...}
    IO.inspect(metadata)      # %{conf: ..., job: ..., state: :success, result: ...}
  end,
  nil
)
```

Measurements: `:duration` (microseconds), `:memory` (bytes), `:queue_time` (microseconds), `:reductions` (Erlang reductions)
Metadata: `:conf`, `:job`, `:state` (`:success`), `:result` (return value)

**Job Exception** — `[:oban, :job, :exception]` fires on failure:

```elixir
:telemetry.attach_handler(
  "oban-job-exception",
  [:oban, :job, :exception],
  fn _event_name, measurements, metadata, _handler_config ->
    %{job: job, kind: kind, reason: reason, stacktrace: stacktrace} = metadata
    Logger.error("Job failed: #{job.worker} - #{inspect(reason)}")
  end,
  nil
)
```

Measurements: `:duration` (microseconds)
Metadata: `:conf`, `:job`, `:kind` (`:error`, `:exit`, `:throw`), `:reason`, `:stacktrace`

**Job State Values** — The `:state` field indicates outcome:

- `:success` — completed successfully
- `:failure` — failed and will retry
- `:cancelled` — job cancelled
- `:discard` — job discarded (retries exhausted)
- `:snoozed` — job snoozed

## Engine Events

Database operation events span specific engine actions for query-level observability:

- `[:oban, :engine, :init]` — queue initialization
- `[:oban, :engine, :refresh]` — queue refresh
- `[:oban, :engine, :put_meta]` — metadata updates
- `[:oban, :engine, :fetch_jobs]` — job fetching
- `[:oban, :engine, :insert_all_jobs]` — bulk inserts
- `[:oban, :engine, :prune_jobs]` — job pruning
- `[:oban, :engine, :cancel_job]` — job cancellation
- `[:oban, :engine, :complete_job]` — job completion

Each engine event provides measurements (duration) and metadata about the operation and affected counts.

## System Events

**Supervisor Init** — `[:oban, :supervisor, :init]` fires on Oban startup:

```elixir
:telemetry.attach_handler(
  "oban-init",
  [:oban, :supervisor, :init],
  fn _event_name, _measurements, %{conf: conf}, _handler_config ->
    Logger.info("Oban initialized with queues: #{inspect(conf.queues)}")
  end,
  nil
)
```

Metadata: `:conf` (Oban.Config)

**Notifier Events** — `[:oban, :notifier, :*]` track notification operations and connectivity:

- `[:oban, :notifier, :init]` — notifier startup
- `[:oban, :notifier, :listen]` — listening started
- `[:oban, :notifier, :notify]` — notification published
- `[:oban, :notifier, :status]` — connectivity status change

Status values: `:unknown`, `:isolated`, `:solitary`, `:clustered`

**Queue Events** — `[:oban, :queue, :*]` signal queue state changes:

- `[:oban, :queue, :shutdown]` — queue shutdown (graceful completion)

**Peer Events** — `[:oban, :peer, :*]` track distributed node leadership:

- `[:oban, :peer, :election]` — leadership election result

**Plugin Events** — `[:oban, :plugin, :*]` monitor plugin execution:

- `[:oban, :plugin, :stop]` — plugin execution completed

## Default Logger Attachment

Oban provides a built-in structured JSON logger:

```elixir
Oban.Telemetry.attach_default_logger()
```

This attaches handlers for all standard events with structured JSON output. Configure logging behavior:

```elixir
Oban.Telemetry.attach_default_logger(
  log_level: :info,
  include: [:job_start, :job_stop, :job_exception],
  exclude: [:engine_events],
  json_encoder: Jason
)
```

**Logger Options:**

- `log_level` — Minimum log level (`:debug`, `:info`, `:warn`, `:error`)
- `include` — Only log specified event types
- `exclude` — Exclude event types from logging
- `json_encoder` — JSON encoding module (default: `Jason`)

## Implementing Custom Telemetry Handlers

Create application-specific handlers for metrics collection:

```elixir
defmodule MyApp.ObanObserver do
  def setup do
    # Track job duration by worker
    :telemetry.attach(
      "oban-duration",
      [:oban, :job, :stop],
      &handle_job_stop/4,
      nil
    )

    # Track job failures
    :telemetry.attach(
      "oban-failure",
      [:oban, :job, :exception],
      &handle_job_exception/4,
      nil
    )
  end

  def handle_job_stop(_event_name, measurements, %{job: job}, _config) do
    :telemetry.execute(
      [:my_app, :job_duration],
      measurements,
      %{worker: job.worker, queue: job.queue}
    )
  end

  def handle_job_exception(_event_name, _measurements, %{job: job, reason: reason}, _config) do
    :telemetry.execute(
      [:my_app, :job_failure],
      %{count: 1},
      %{worker: job.worker, error: inspect(reason)}
    )
  end
end
```

Call `MyApp.ObanObserver.setup()` during application startup to install handlers.

## Metrics Collection Example

Collect metrics using a metrics library like `:prometheus_ex`:

```elixir
defmodule MyApp.ObanMetrics do
  def setup do
    :telemetry.attach_many(
      "oban-metrics",
      [
        [:oban, :job, :start],
        [:oban, :job, :stop],
        [:oban, :job, :exception]
      ],
      &handle_event/4,
      nil
    )
  end

  def handle_event([:oban, :job, :start], _measurements, _metadata, _config) do
    Prometheus.Counter.inc(:oban_jobs_started)
  end

  def handle_event([:oban, :job, :stop], measurements, metadata, _config) do
    Prometheus.Counter.inc(:oban_jobs_completed)
    Prometheus.Histogram.observe(
      :oban_job_duration_microseconds,
      measurements.duration,
      labels: [metadata.job.worker]
    )
  end

  def handle_event([:oban, :job, :exception], _measurements, metadata, _config) do
    Prometheus.Counter.inc(:oban_jobs_failed, labels: [metadata.job.worker])
  end
end
```

---

[← Back to main](oban-2.20.3.md)
**Version:** 2.20.3
