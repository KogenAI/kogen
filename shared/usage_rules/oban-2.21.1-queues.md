# oban - Queue Management & Control

## Queue Basics

Queues are logical groupings of jobs with independent concurrency limits. Configure queues in your Oban config:

```elixir
config :my_app, Oban,
  queues: [
    default: 10,      # 10 workers
    mailers: 20,      # 20 workers
    critical: 5,      # 5 workers
    background: 2     # 2 workers
  ]
```

Each queue runs in its own supervised process with its own worker pool, allowing fine-grained concurrency control per job type.

## Queue Lifecycle

### Starting Queues

Start a queue at runtime (already started via supervision tree by default):

```elixir
Oban.start_queue(:new_queue, limit: 15)
```

Useful for dynamically adding queues without application restart.

### Stopping Queues

Stop a queue to prevent new job execution:

```elixir
Oban.stop_queue(:background)
```

Stopping does not terminate executing jobs—only prevents new ones from starting. Use with caution in production.

### Pausing Queues

Pause a queue to halt new job execution while maintaining process health:

```elixir
Oban.pause_queue(:mailers)
```

Useful for maintenance windows or rate-limiting without full shutdown.

### Resuming Queues

Resume a paused queue:

```elixir
Oban.resume_queue(:mailers)
```

Previously paused jobs resume execution immediately.

### Scaling Queues

Adjust concurrency at runtime:

```elixir
Oban.scale_queue(:mailers, limit: 30)
```

Increasing limit spawns new workers; decreasing waits for existing jobs to finish before terminating workers.

## Queue Status & Inspection

Check queue health and configuration:

```elixir
# Check specific queue
case Oban.check_queue(:mailers) do
  {:ok, state} -> IO.inspect(state)
  {:error, reason} -> IO.inspect(reason)
end

# Check all queues
Oban.check_all_queues()
```

Returns queue state, worker counts, and execution metrics.

## Draining Queues (Testing)

Synchronously execute queued jobs for testing:

```elixir
defmodule MyApp.MyTest do
  use ExUnit.Case

  test "jobs process correctly" do
    MyApp.SomeWorker.new(%{id: 1}) |> Oban.insert()

    # Execute all available jobs
    Oban.drain_queue(:default)

    # Verify work completed
    assert user_updated?
  end
end
```

Drain options:

- **`:with_limit`** — Process maximum N jobs per iteration: `with_limit: 5`
- **`:with_recursion`** — Continue draining if jobs spawn new jobs: `with_recursion: true`
- **`:with_safety`** — Exception handling behavior
- **`:with_scheduled`** — Include scheduled jobs in drain: `with_scheduled: true`

## Performance Considerations

**Concurrency Limits** — Set queue limits based on resource constraints:

- I/O-bound jobs (HTTP, database): higher limits (20-50)
- CPU-bound jobs: limit to CPU core count
- Memory-intensive jobs: lower limits (2-5)

**Multiple Queues** — Use separate queues for different job types to prevent resource contention:

```elixir
config :my_app, Oban,
  queues: [
    critical: 10,     # Important, fast jobs
    default: 5,       # General work
    heavy: 2          # Memory/CPU intensive
  ]
```

**Job Distribution** — Route jobs to appropriate queues in workers:

```elixir
defmodule MyApp.ProcessImageWorker do
  use Oban.Worker, queue: :heavy  # Runs on heavy queue

  def perform(%Job{args: %{"image_id" => id}}) do
    process_large_image(id)
    :ok
  end
end
```

## Graceful Shutdown

Oban waits for executing jobs during shutdown (configurable via `shutdown_grace_period`):

```elixir
# Default: 15 seconds
config :my_app, Oban,
  shutdown_grace_period: 30_000  # 30 seconds
```

If jobs don't complete within the grace period, workers are forcefully terminated. Increase for long-running jobs.

## Database Monitoring

Query job counts by queue and state:

```elixir
# Count jobs per queue
Oban.Job
|> where([j], j.state in ["available", "executing"])
|> group_by([j], j.queue)
|> select([j], {j.queue, count(j.id)})
|> MyApp.Repo.all()

# Recent errors
Oban.Job
|> where([j], j.state == "discarded")
|> order_by([j], desc: j.updated_at)
|> limit(10)
|> MyApp.Repo.all()
```

## Orphaned Jobs

Jobs may remain in "executing" state if workers crash unexpectedly. Solutions:

1. **Lifeline Plugin** — Automatically recovers orphaned jobs:

   ```elixir
   config :my_app, Oban,
     plugins: [Oban.Plugins.Lifeline]
   ```

2. **Increase Grace Period** — Allow more time for jobs to complete:

   ```elixir
   config :my_app, Oban,
     shutdown_grace_period: 60_000
   ```

3. **Manual Recovery** — Query and retry orphaned jobs:
   ```elixir
   Oban.Job
   |> where([j], j.state == "executing" and j.updated_at < ago(1, "hour"))
   |> MyApp.Repo.all()
   |> Enum.each(&Oban.retry_job/1)
   ```

---

[← Back to main](oban-2.21.1.md)  
**Version:** 2.21.1
