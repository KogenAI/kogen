# oban - Telemetry & Monitoring

## Telemetry Overview

Oban emits structured telemetry events for monitoring job execution, system operations, and plugin activity. Attach handlers to these events for logging, metrics collection, and error reporting.

## Event Categories

### Job Events

Track individual job execution:

- **`[:oban, :job, :start]`** - Job fetched and ready to execute
- **`[:oban, :job, :stop]`** - Job succeeded
- **`[:oban, :job, :exception]`** - Job failed

#### Job Event Measurements

```elixir
%{
  duration: 234,      # Execution time in microseconds
  memory: 512000,     # Memory allocated by job
  queue_time: 1000,   # Time spent waiting in queue
  reductions: 45000   # Erlang reductions count
}
```

#### Job Event Metadata

```elixir
%{
  job: %Oban.Job{...},           # Complete job struct
  state: :success,                # Job outcome state
  worker: "MyApp.Workers.SendEmail",
  queue: "mailers",
  attempt: 1,
  max_attempts: 20,
  reason: "email sent",           # For :stop events

  # For :exception events only
  kind: :error,                   # :error, :exit, :throw
  reason: "rate limit exceeded",
  stacktrace: [...]
}
```

### Engine Events

Monitor database operations (insert, fetch, stage, etc.):

- **`[:oban, :engine, :start]`** - Operation starting
- **`[:oban, :engine, :stop]`** - Operation completed
- **`[:oban, :engine, :exception]`** - Operation failed

Operations include: `fetch_jobs`, `insert_all_jobs`, `cancel_job`, `retry_job`, `delete_job`, `complete_job`, `error_job`, `discard_job`, `prune_jobs`, `stage_jobs`.

### Infrastructure Events

Track system-level operations:

- **`[:oban, :notifier, :status]`** - Notifier status change
- **`[:oban, :peer, :election]`** - Leadership election
- **`[:oban, :queue, :shutdown]`** - Queue shutdown
- **`[:oban, :stager, :start]`** - Stager mode change (local/global)

Notifier statuses:

```elixir
:unknown    # Initial state
:isolated   # Unable to receive messages from other sources
:solitary   # Only receiving self-generated messages
:clustered  # Connected to other nodes
```

### Plugin Events

Custom events emitted by plugins:

- **`[:oban, :plugin, *]`** - Plugin-specific events

## Attaching Event Handlers

### Basic Handler

```elixir
defmodule MyApp.TelemetryHandler do
  require Logger

  def handle_event([:oban, :job, :stop], %{duration: duration},
                   %{worker: worker, queue: queue}, nil) do
    Logger.info("Job completed",
      worker: worker,
      queue: queue,
      duration_ms: duration / 1000
    )
  end

  def handle_event([:oban, :job, :exception], %{duration: duration},
                   %{kind: kind, reason: reason, job: job}, nil) do
    Logger.error("Job failed",
      worker: job.worker,
      error: reason,
      kind: kind
    )
  end
end

# Attach handler
:telemetry.attach(
  "my-app-jobs",
  [:oban, :job, :stop],
  &MyApp.TelemetryHandler.handle_event/4,
  nil
)
```

### Event Filtering

Attach to multiple events at once:

```elixir
:telemetry.attach_many(
  "oban-events",
  [
    [:oban, :job, :start],
    [:oban, :job, :stop],
    [:oban, :job, :exception]
  ],
  &MyApp.TelemetryHandler.handle_event/4,
  nil
)
```

Conditional filtering inside handler:

```elixir
def handle_event(event, measurements, meta, nil) do
  case event do
    [:oban, :job, :exception] when meta.attempt >= meta.max_attempts ->
      report_failure(meta)

    [:oban, :job, :exception] ->
      # Retry in progress, no action
      :ok

    [:oban, :job, :stop] ->
      log_completion(meta, measurements)

    _ ->
      :ok
  end
end
```

## Default Logger Integration

Attach Oban's built-in structured JSON logger:

```elixir
Oban.Telemetry.attach_default_logger(:info)
```

Configuration options:

```elixir
Oban.Telemetry.attach_default_logger(
  :info,
  encode: true,                          # JSON output (default: true)
  events: [:job, :notifier, :peer],     # Filter by category
  level: :info                           # Log level
)
```

**Output example:**

```json
{
  "source": "oban",
  "message": "Job succeeded",
  "queue": "mailers",
  "worker": "MyApp.Workers.SendEmail",
  "duration_ms": 234.5
}
```

## Error Reporting Integration

### Honeybadger Integration

```elixir
defmodule MyApp.ErrorReporting do
  require Logger

  def attach_honeybadger() do
    :telemetry.attach(
      "oban-honeybadger",
      [:oban, :job, :exception],
      &handle_error/4,
      []
    )
  end

  def handle_error([:oban, :job, :exception], %{duration: _},
                   %{job: job, reason: reason, kind: kind, stacktrace: trace}, nil) do
    # Only report on final failure
    if job.attempt >= job.max_attempts do
      Honeybadger.notify(
        error_message: reason,
        error_class: kind,
        backtrace: trace,
        context: %{
          worker: job.worker,
          queue: job.queue,
          job_id: job.id,
          attempts: job.attempt
        }
      )
    end
  end
end
```

### Sentry Integration

```elixir
def handle_error([:oban, :job, :exception], _measurements,
                 %{job: job, reason: reason, kind: kind}, _config) do
  if job.attempt >= job.max_attempts do
    Sentry.capture_exception(
      Exception.new(kind, reason),
      extra: %{
        job_id: job.id,
        worker: job.worker,
        queue: job.queue,
        max_attempts: job.max_attempts
      }
    )
  end
end
```

## Custom Metrics

### Prometheus Integration

```elixir
defmodule MyApp.MetricsHandler do
  def attach_prometheus() do
    :telemetry.attach_many(
      "oban-prometheus",
      [
        [:oban, :job, :start],
        [:oban, :job, :stop],
        [:oban, :job, :exception]
      ],
      &handle_event/4,
      []
    )
  end

  def handle_event([:oban, :job, :start], _, %{job: job}, _) do
    :prometheus_counter.inc(:oban_jobs_started, [job.queue, job.worker])
  end

  def handle_event([:oban, :job, :stop], measurements, %{job: job}, _) do
    :prometheus_counter.inc(:oban_jobs_completed, [job.queue, job.worker])
    :prometheus_histogram.observe(
      :oban_job_duration_microseconds,
      [job.queue, job.worker],
      measurements.duration
    )
  end

  def handle_event([:oban, :job, :exception], _, %{job: job}, _) do
    :prometheus_counter.inc(:oban_jobs_failed, [job.queue, job.worker])
  end
end
```

## Monitoring Connectivity

Check notifier status for distributed deployments:

```elixir
status = Oban.Notifier.status(Oban)

case status do
  :clustered ->
    Logger.info("All nodes connected")

  :isolated ->
    Logger.warning("No other nodes detected - queue operations may fail")

  :solitary ->
    Logger.warning("Can only receive own messages")

  :unknown ->
    Logger.info("Notifier status not yet determined")
end
```

## Performance Monitoring

Track queue performance metrics:

```elixir
def handle_event([:oban, :job, :stop],
                 %{duration: duration, queue_time: queue_time},
                 %{queue: queue, worker: worker}, _) do
  # Alert if jobs taking too long
  if duration > 30_000_000 do  # 30 seconds
    Logger.warning("Slow job",
      worker: worker,
      duration_ms: duration / 1000,
      queue_time_ms: queue_time / 1000
    )
  end

  # Alert on queue buildup
  if queue_time > 60_000_000 do  # 60 seconds wait time
    Logger.warning("Queue backlog detected",
      queue: queue,
      wait_time_ms: queue_time / 1000
    )
  end
end
```

---

[← Back to main](oban-2.20.1.md)
**Version:** 2.20.1
