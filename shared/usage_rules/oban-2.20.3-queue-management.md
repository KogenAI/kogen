# oban - Queue Management & Runtime Control

## Queue Configuration

Queues are defined in application configuration as a map or keyword list with concurrency limits:

```elixir
config :my_app, Oban,
  repo: MyApp.Repo,
  queues: [
    default: 10,      # max 10 concurrent jobs
    events: 20,
    batch_processing: 5,
    critical: [limit: 30, paused: true]  # start paused
  ]
```

Each queue runs independently with isolated concurrency, allowing fine-grained control over resource allocation. A queue with limit 10 will execute up to 10 jobs concurrently; other queues are unaffected.

**Queue Configuration Options:**

- `limit` — Maximum concurrent jobs (alternative to bare integer)
- `paused` — Start queue in paused state (`true/false`, default: `false`)
- `partition_size` — Jobs per database query (tuning option, default: varies)

## Runtime Queue Control

Manipulate queue state at runtime using the `Oban` module functions. All queue operations require a working notifier for multi-node coordination.

**Starting/Stopping:**

```elixir
# Start processing a queue
Oban.start_queue(MyApp.Oban, :critical)

# Stop processing (in-flight jobs complete, new jobs wait)
Oban.stop_queue(MyApp.Oban, :events)
```

**Pausing/Resuming:**

```elixir
# Pause queue (stop processing new jobs, don't shutdown)
Oban.pause_queue(MyApp.Oban, :batch_processing)

# Resume processing
Oban.resume_queue(MyApp.Oban, :batch_processing)
```

**Scaling Concurrency:**

```elixir
# Dynamically adjust concurrency limit
Oban.scale_queue(MyApp.Oban, :default, limit: 20)  # increase from 10 to 20
Oban.scale_queue(MyApp.Oban, :events, limit: 5)    # decrease
```

**Health Checks:**

```elixir
# Get queue status and metrics
Oban.check_queue(MyApp.Oban, :default)
# returns queue state, concurrency, limits, job counts
```

## Job State Management

Manipulate individual jobs at runtime using `Oban` functions.

**Cancelling Jobs:**

```elixir
# Cancel a scheduled or executing job
Oban.cancel_job(MyApp.Oban, job_id)

# Returns :ok on success, {:error, reason} if job not found or already terminal
```

Cancelled jobs transition to `:cancelled` state and do not retry. In-flight jobs are interrupted; cancelled scheduled jobs never execute.

**Retrying Failed Jobs:**

```elixir
# Move a failed/discarded job back to retryable
Oban.retry_job(MyApp.Oban, job_id)

# Reset attempt counter and reschedule
```

Retried jobs reset their attempt count and transition to `:retryable`, scheduling execution after backoff.

**Deleting Jobs:**

```elixir
# Permanently delete a job
Oban.delete_job(MyApp.Oban, job_id)
```

Only non-executing jobs can be deleted. Use `cancel_job/2` to stop executing jobs.

**Updating Job Fields:**

```elixir
# Update job metadata at runtime
Oban.update_job(MyApp.Oban, job,
  args: %{"updated_key" => "new_value"},
  tags: ["critical"],
  meta: %{"version" => 2}
)
```

## Testing: Draining Queues

Use `drain_queue/2` in tests to synchronously process all available jobs:

```elixir
test "processes all pending jobs" do
  # enqueue jobs...
  {:ok, jobs} = Oban.drain_queue(MyApp.Oban, :default)
  assert length(jobs) == expected_count
end
```

`drain_queue/2` executes available jobs in the test process sequentially, bypassing concurrency limits. Useful for integration testing.

## Graceful Shutdown

Oban supports graceful shutdown with a configurable grace period for job completion:

```elixir
config :my_app, Oban,
  shutdown_grace_period: 30_000  # 30 seconds to finish in-flight jobs
```

When the application stops, Oban waits up to the grace period for executing jobs to complete. Jobs exceeding the grace period are interrupted; their state is saved for resumption on restart.

## Supervision Tree Integration

Oban must be added to your application's supervision tree as a supervisor:

```elixir
def start(_type, _args) do
  children = [
    MyApp.Repo,
    {Oban, Application.fetch_env!(:my_app, Oban)},
    # other children...
  ]

  Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)
end
```

Oban starts its own internal supervision tree with queue supervisors, job executors, and monitoring processes.

## Distributed Queue Coordination

In multi-node deployments, queue state is coordinated via the notifier. Pause, resume, scale, and start/stop commands propagate to all nodes running the same queue.

Ensure your notifier is configured and connected:

```elixir
config :my_app, Oban,
  notifier: {Oban.Notifiers.Postgres, []}  # or Phoenix, or PG
```

Without a connected notifier, commands target only the local node.

---

[← Back to main](oban-2.20.3.md)
**Version:** 2.20.3
