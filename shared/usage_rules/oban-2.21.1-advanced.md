# oban - Advanced Topics & Pro Features

## Oban Pro

Oban Pro is a licensed commercial offering extending core Oban with enterprise features.

### Smart Engine

Global concurrency and rate limiting across distributed nodes:

```elixir
config :my_app, Oban,
  engine: Oban.Pro.Engines.Smart,
  global_limit: 100  # Max 100 concurrent jobs across all nodes
```

Ensures expensive operations don't overwhelm external APIs or resources.

### Workflows

Define job dependencies and execute in sequence:

```elixir
defmodule MyApp.ReportWorkflow do
  use Oban.Pro.Workflow

  def build(%{"report_id" => id}) do
    Workflow.new()
    |> add_job(GenerateDataWorker, %{"report_id" => id})
    |> add_job(ProcessDataWorker, %{"report_id" => id}, deps: [GenerateDataWorker])
    |> add_job(PublishReportWorker, %{"report_id" => id}, deps: [ProcessDataWorker])
  end
end

# Enqueue entire workflow
MyApp.ReportWorkflow.new(%{"report_id" => 123}) |> Oban.insert()
```

Jobs execute only when dependencies complete successfully.

### Batches

Group related jobs and process with progress tracking:

```elixir
defmodule MyApp.EmailBatchWorker do
  use Oban.Pro.Batch

  def perform(%Batch{jobs: jobs}) do
    Enum.each(jobs, &send_email/1)
    :ok
  end
end

# Create batch
batch = Oban.Pro.Batch.new([
  EmailBatchWorker.new(%{email: "user1@example.com"}),
  EmailBatchWorker.new(%{email: "user2@example.com"}),
  EmailBatchWorker.new(%{email: "user3@example.com"})
])

# Process as group
Oban.Pro.Batch.insert(batch)
```

Batches provide progress callbacks and aggregated error handling.

### Dynamic CRON

Modify cron schedules at runtime without restart:

```elixir
# Update schedule
Oban.Pro.Cron.update(MyApp.DailyWorker, "0 3 * * *")

# Disable/enable
Oban.Pro.Cron.disable(MyApp.DailyWorker)
Oban.Pro.Cron.enable(MyApp.DailyWorker)

# Delete
Oban.Pro.Cron.delete(MyApp.DailyWorker)
```

## Plugins

Extend Oban with plugins for specialized behavior:

### Lifeline Plugin

Recovers orphaned jobs stuck in "executing" state:

```elixir
config :my_app, Oban,
  plugins: [Oban.Plugins.Lifeline]
```

Periodically checks for executing jobs that haven't updated recently and moves them to retry.

### Cron Plugin

Automatically enqueues periodic jobs:

```elixir
config :my_app, Oban,
  plugins: [
    {Oban.Plugins.Cron, crontab: [
      {"0 2 * * *", MyApp.DailyReportWorker},
      {"*/15 * * * *", MyApp.HealthCheckWorker}
    ]}
  ]
```

### Pruner Plugin

Automatically delete old completed/discarded jobs to reduce database size:

```elixir
config :my_app, Oban,
  plugins: [
    {Oban.Plugins.Pruner, max_age: 2_592_000}  # 30 days
  ]
```

## Notifiers

Choose notifier backend for cross-node coordination:

### Postgres Notifier (Default)

Uses PostgreSQL's LISTEN/NOTIFY:

```elixir
config :my_app, Oban,
  notifier: {Oban.Notifiers.Postgres, []}
```

Advantages: Native PostgreSQL, no extra infrastructure.  
Disadvantages: Breaks with PgBouncer transaction pooling.

### PG Notifier

Uses Distributed Erlang process groups (no LISTEN/NOTIFY):

```elixir
config :my_app, Oban,
  notifier: {Oban.Notifiers.PG, []}
```

Advantages: Works with PgBouncer, no external services.  
Disadvantages: Requires Erlang distribution enabled.

### Phoenix Notifier

Uses Phoenix.PubSub with flexible transports:

```elixir
config :my_app, Oban,
  notifier: {Oban.Notifiers.Phoenix, pubsub: MyApp.PubSub}
```

Advantages: Flexible transport (Redis, Postgres), integrates with existing PubSub.

## Ecto Integration

Work with jobs using standard Ecto queries:

```elixir
import Ecto.Query

# Count pending jobs
Oban.Job
|> where([j], j.state in ["available", "executing", "scheduled"])
|> MyApp.Repo.aggregate(:count)

# Find jobs by tag
Oban.Job
|> where([j], fragment("? @> ?", j.tags, ^["urgent"]))
|> MyApp.Repo.all()

# Delete old jobs
Oban.Job
|> where([j], j.state == "completed" and j.updated_at < ago(30, "day"))
|> MyApp.Repo.delete_all()
```

## Custom Engines

Implement custom job execution engines:

```elixir
defmodule MyApp.CustomEngine do
  @behaviour Oban.Engine

  def init(config), do: config

  def insert_job(repo, job, _opts) do
    # Custom insertion logic
    {:ok, job}
  end

  # Implement other required callbacks...
end

config :my_app, Oban,
  engine: MyApp.CustomEngine
```

## Performance Tuning

**Connection Pool Size:**

Ensure sufficient database connections:

```elixir
# Number of connections ≥ largest queue limit + 2-3 buffer
config :my_app, MyApp.Repo,
  pool_size: 25
```

**Staged vs Global Mode:**

Oban uses "staged" mode (local job staging) in single-node setups and "global" mode (database-driven staging) in multi-node deployments. Verify leadership for global mode:

```elixir
# Check mode
Oban.check_all_queues()

# Promote to leadership if needed
Oban.Peers.Global.leader?()
```

**Job Complexity:**

Keep individual jobs focused and fast:

```elixir
# Good: Small, focused job
defmodule MyApp.SendEmailWorker do
  use Oban.Worker
  def perform(%{args: %{"email" => email}}) do
    send_email(email)
    :ok
  end
end

# Avoid: Complex multi-step job
defmodule MyApp.ProblematicWorker do
  use Oban.Worker
  def perform(%{args: %{"user_id" => id}}) do
    user = fetch_user(id)
    data = generate_report(user)
    emails = send_notifications(data)
    archive_results(emails)
    # Too much in one job; break into pipeline
    :ok
  end
end
```

## Error Handling Strategies

### Transient vs Permanent Errors

```elixir
def perform(%Job{args: args, attempt: attempt}) do
  case do_work(args) do
    {:ok, result} ->
      :ok

    {:error, :network_timeout} when attempt < 5 ->
      # Transient: retry with backoff
      {:error, "Network timeout, will retry"}

    {:error, :resource_not_found} ->
      # Permanent: cancel without retry
      {:cancel, "Resource does not exist"}

    {:error, :rate_limited} ->
      # Rate limit: snooze to preserve retries
      {:snooze, 300}

    {:error, reason} ->
      # Unknown: retry
      {:error, reason}
  end
end
```

### Exponential Backoff

```elixir
def backoff(%Job{attempt: attempt}) do
  # Linear backoff: 60s, 120s, 240s...
  attempt * 60
end

def backoff(%Job{attempt: attempt}) do
  # Exponential: 2s, 4s, 8s, 16s...
  Integer.pow(2, attempt)
end
```

## Distributed Deployment

**Multi-Node Setup:**

```elixir
# Worker node
config :my_app, Oban,
  peer: Oban.Peers.Global,
  queues: [default: 10],
  notifier: {Oban.Notifiers.Postgres, []}

# Web node (no job processing)
config :my_app, Oban,
  peer: false,
  queues: []
```

**Graceful Restart:**

Use global peer to prevent leadership flapping:

```elixir
config :my_app, Oban,
  peer: Oban.Peers.Global  # More stable than default
```

---

[← Back to main](oban-2.21.1.md)  
**Version:** 2.21.1
