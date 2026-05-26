# oban - Monitoring, Telemetry & Troubleshooting

## Telemetry Integration

Oban emits telemetry events for monitoring job lifecycle. Subscribe to events:

```elixir
defmodule MyApp.ObanTelemetry do
  def handle_event(event, measurements, metadata, _config) do
    IO.inspect({event, measurements, metadata})
  end

  def attach_handlers do
    # Job execution events
    :telemetry.attach("oban-job-start", [:oban, :job, :start], &handle_event/4, nil)
    :telemetry.attach("oban-job-stop", [:oban, :job, :stop], &handle_event/4, nil)
    :telemetry.attach("oban-job-exception", [:oban, :job, :exception], &handle_event/4, nil)

    # Queue events
    :telemetry.attach("oban-queue-start", [:oban, :queue, :start], &handle_event/4, nil)
    :telemetry.attach("oban-queue-stop", [:oban, :queue, :stop], &handle_event/4, nil)
  end
end

# Attach in application startup
MyApp.ObanTelemetry.attach_handlers()
```

Key telemetry events:

- **`[:oban, :job, :start]`** — Job execution beginning
- **`[:oban, :job, :stop]`** — Job execution completed (success or failure)
- **`[:oban, :job, :exception]`** — Job crashed with unhandled exception
- **`[:oban, :queue, :start]`** — Queue started
- **`[:oban, :queue, :stop]`** — Queue stopped

## Notifier Status

Monitor cross-node coordination via notifiers:

```elixir
# Check notifier connectivity status
case Oban.Notifier.status(MyApp.Oban) do
  :clustered  -> IO.puts("Connected to other nodes")
  :solitary   -> IO.puts("Single node, local messages only")
  :isolated   -> IO.puts("Cannot receive external messages")
  :unknown    -> IO.puts("Status unknown")
end
```

Status meanings:

- **`:clustered`** — Notifier can receive messages from other nodes
- **`:solitary`** — Only receives own messages (expected in single-node setups)
- **`:isolated`** — Cannot receive external messages (indicates connectivity problem)
- **`:unknown`** — Status not yet determined

## Logging

Control Oban's logging output:

```elixir
config :my_app, Oban,
  log: :info    # :debug, :info, :warn, :error, or false
```

Oban logs queue state transitions, job completions, and error details.

## Metrics & Dashboard

Query job metrics directly from the database:

```elixir
# Jobs per queue
Oban.Job
|> group_by([j], j.queue)
|> select([j], {j.queue, count(j.id)})
|> MyApp.Repo.all()

# Job state distribution
Oban.Job
|> group_by([j], j.state)
|> select([j], {j.state, count(j.id)})
|> MyApp.Repo.all()

# Failed jobs
Oban.Job
|> where([j], j.state in ["discarded", "cancelled"])
|> order_by([j], desc: j.updated_at)
|> MyApp.Repo.all()

# Jobs by worker
Oban.Job
|> where([j], j.state in ["available", "executing"])
|> group_by([j], j.worker)
|> select([j], {j.worker, count(j.id)})
|> MyApp.Repo.all()
```

## Troubleshooting

### Jobs Stuck in Executing State

Jobs may remain "executing" if workers crash unexpectedly. Solutions:

1. **Enable Lifeline Plugin:**

   ```elixir
   config :my_app, Oban,
     plugins: [Oban.Plugins.Lifeline]
   ```

   Automatically recovers orphaned jobs.

2. **Increase Shutdown Grace Period:**

   ```elixir
   config :my_app, Oban,
     shutdown_grace_period: 30_000  # 30 seconds
   ```

3. **Manual Recovery (via RPC or IEx):**

   ```elixir
   import Ecto.Query

   Oban.Job
   |> where([j], j.state == "executing" and j.updated_at < ago(1, "hour"))
   |> MyApp.Repo.all()
   |> Enum.each(&Oban.retry_job/1)
   ```

### Plugins Stop Working in Multi-Node Setups

On multi-node clusters, non-worker nodes (e.g., web nodes) may become leaders, making plugins dormant:

**Solution:** Disable leadership on non-worker nodes:

```elixir
# config for web nodes only
config :my_app, Oban,
  peer: false,
  queues: []
```

### CRON @reboot Not Triggering After Restart

Leadership coordination delays may prevent timely cron job insertion:

**Solutions:**

1. Wait ~30 seconds for leadership to stabilize
2. Use `Oban.Peers.Global` for graceful restarts
3. Manually clear peer state in tests: `MyApp.Repo.query!("DELETE FROM oban_peers")`

### PgBouncer Transaction Pooling Issues

PgBouncer's transaction pooling disables PostgreSQL's LISTEN/NOTIFY:

**Solutions:**

1. Switch to `Oban.Notifiers.PG` (uses Erlang process groups)
2. Use PgBouncer's Session Pooling mode instead of Transaction Pooling
3. Bypass PgBouncer with a dedicated connection for Oban

```elixir
config :my_app, Oban,
  notifier: {Oban.Notifiers.PG, []}
```

### Excessive Database Queries

If every queue polls the database every second, job staging likely switched to local mode:

**Root Cause:** Leadership not established or pubsub notifications failing

**Solution:**

1. Verify leadership: `Oban.Peers.Global.leader?/1`
2. Check notifier status: `Oban.Notifier.status/1`
3. Ensure peer is enabled: `config :my_app, Oban, peer: true`

### Migrations Re-running

Missing version comments on the `oban_jobs` table trigger full migration replay:

**Solution:** Manually set the comment:

```sql
COMMENT ON TABLE oban_jobs IS 'oban_jobs_version:13';
-- Replace '13' with the latest migration number
```

## Performance Optimization

**Tune Concurrency:**

```elixir
config :my_app, Oban,
  queues: [
    io_bound: 30,      # HTTP, database operations
    cpu_bound: 4,      # CPU intensive
    memory_heavy: 2    # Memory intensive
  ]
```

**Monitor Database Connection Pool:**

Ensure your Repo has sufficient connections for Oban workers:

```elixir
config :my_app, MyApp.Repo,
  pool_size: 15  # At least max queue size + buffer
```

**Use Batch Operations:**

Insert multiple jobs atomically:

```elixir
jobs = Enum.map(data, &MyApp.Worker.new/1)
Oban.insert_all(jobs)
```

Faster than inserting jobs individually.

---

[← Back to main](oban-2.21.1.md)  
**Version:** 2.21.1
