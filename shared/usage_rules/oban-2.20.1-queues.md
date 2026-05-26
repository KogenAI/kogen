# oban - Queue Management

## Queue Configuration

Configure queues at startup in `config/config.exs`:

```elixir
config :my_app, Oban,
  repo: MyApp.Repo,
  queues: [
    default: 10,      # 10 concurrent jobs
    mailers: 5,       # 5 concurrent email jobs
    reports: 2        # 2 concurrent report jobs
  ]
```

### Queue Names & Concurrency

Queue names are arbitrary atoms (`:default`, `:mailers`, `:background`, etc.). The concurrency value specifies maximum simultaneous workers for that queue.

## Queue Lifecycle Operations

Oban provides runtime queue management functions:

### Starting & Stopping Queues

```elixir
# Start a queue
Oban.start_queue(Oban, :reports, concurrency: 4)

# Stop a queue (waits for running jobs)
Oban.stop_queue(Oban, :reports)
```

### Pause & Resume

Control queue execution without removing the queue:

```elixir
# Pause queue - no new jobs start
Oban.pause_queue(Oban, :mailers)

# Resume queue - jobs continue processing
Oban.resume_queue(Oban, :mailers)
```

### Scale Queue Concurrency

Adjust concurrency at runtime:

```elixir
# Increase concurrency during peak hours
Oban.scale_queue(Oban, :mailers, concurrency: 20)

# Decrease for maintenance
Oban.scale_queue(Oban, :mailers, concurrency: 2)
```

### Check Queue Status

Inspect queue state:

```elexir
Oban.check_queue(Oban, :mailers)
# Returns: {:ok, %{paused: false, ...}} or {:error, reason}
```

## Job Control Operations

### Cancel Jobs

Stop jobs mid-execution or prevent scheduled jobs from running:

```elixir
# Cancel specific job
Oban.cancel_job(Oban, job_id)

# Cancel multiple jobs (by query)
Oban.cancel_job(Oban, MyApp.Workers.SendEmail)
```

### Retry Jobs

Force retry of failed jobs:

```elixir
# Retry specific job
Oban.retry_job(Oban, job_id)

# Reset attempt counter before retry
Oban.retry_job(Oban, job_id)
```

### Delete Jobs

Permanently remove jobs from the database:

```elixir
Oban.delete_job(Oban, job_id)
```

## Testing Queue Execution

Synchronously execute jobs in tests using `drain_queue`:

```elixir
# Execute all available jobs in default queue
Oban.drain_queue(Oban, queue: :default)

# Execute only scheduled jobs becoming available
Oban.drain_queue(Oban, queue: :default, with_scheduled: true)

# Execute up to N jobs
Oban.drain_queue(Oban, queue: :default, limit: 5)

# Use safe mode (requires explicit safety confirmation)
Oban.drain_queue(Oban, queue: :default, safe: true)
```

## Queue Isolation

Oban queues are isolated by name and concurrency:

- Jobs enqueued to `:mailers` only execute in `:mailers` workers
- Changing `:default` concurrency doesn't affect `:mailers`
- Pausing one queue doesn't pause others
- Each queue maintains independent metrics

## Distributed Queue Coordination

In multi-node deployments, queues coordinate through the notifier:

```elixir
# Pause affects all nodes
Oban.pause_queue(Oban, :mailers)

# Scale adjusts concurrency cluster-wide
Oban.scale_queue(Oban, :mailers, concurrency: 15)
```

**Critical Note**: Queue operations like `pause_queue`, `scale_queue`, and `cancel_job` **require a connected notifier** to operate across nodes.

## Queue Monitoring

Track queue health in production:

```elixir
# Telemetry events for queue operations
:telemetry.attach("queue-monitor", [:oban, :queue, :initialized],
  &monitor_queue_init/4, nil)

# Check queue status periodically
{:ok, status} = Oban.check_queue(Oban, :mailers)
```

## Multi-Queue Patterns

### Workflow: Splitting Work

```elixir
defmodule MyApp.Workers.ProcessOrder do
  use Oban.Worker, queue: :orders

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"order_id" => id}}) do
    order = Repo.get(Order, id)

    # Delegate payment to payment queue
    %{"order_id" => id}
    |> MyApp.Workers.ProcessPayment.new(queue: :payments)
    |> Oban.insert()

    # Delegate email to mailers queue
    %{"order_id" => id}
    |> MyApp.Workers.SendConfirmation.new(queue: :mailers)
    |> Oban.insert()

    :ok
  end
end
```

### Resource-Specific Isolation

```elixir
# CPU-intensive jobs on dedicated queue with low concurrency
config :my_app, Oban,
  queues: [
    default: 10,
    cpu_intensive: 2,    # Low concurrency for expensive ops
    io_bound: 50,        # High concurrency for I/O tasks
    critical: 20         # High priority critical queue
  ]
```

## Queue Performance Tuning

### Concurrency Guidelines

- **I/O operations** (API calls, database): 10-50 depending on resource limits
- **CPU operations** (processing, transformation): 2-4 per CPU core
- **Email/notifications**: 5-20 depending on rate limits
- **Default**: 10 is safe starting point

### Dynamic Adjustment

```elixir
# Increase during peak hours (scheduled via cron)
defmodule MyApp.Workers.ScaleQueues do
  use Oban.Worker, queue: :system

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case current_hour() do
      hour when hour in 8..17 ->  # Business hours
        Oban.scale_queue(Oban, :mailers, concurrency: 30)
      _ ->
        Oban.scale_queue(Oban, :mailers, concurrency: 5)
    end
    :ok
  end

  defp current_hour() do
    DateTime.utc_now().hour
  end
end
```

---

[← Back to main](oban-2.20.1.md)
**Version:** 2.20.1
