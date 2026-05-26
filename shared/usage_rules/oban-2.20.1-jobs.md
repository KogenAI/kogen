# oban - Job Configuration & Options

## Job Structure

`Oban.Job` is an Ecto schema representing asynchronous tasks. Jobs are created as changesets and inserted into the database, enabling atomic transaction support—jobs only execute if their parent transaction succeeds.

### Core Job Fields

- `args` - Map containing job parameters (required)
- `worker` - Module implementing `Oban.Worker` behavior (required)
- `queue` - Named queue for job routing (default: "default")
- `state` - Current job lifecycle stage (scheduled, available, executing, completed, retryable, discarded, cancelled)
- `attempt` - Current attempt number (1-indexed)
- `max_attempts` - Retry limit before discard (default: 20)
- `priority` - 0-9 ranking where 0 is highest priority (default: 0)
- `tags` - Organizational labels as strings (default: `[]`)
- `meta` - Additional metadata map (default: `%{}`)
- `scheduled_at` - Future execution timestamp (default: current time)
- `completed_at` - Completion timestamp if finished
- `inserted_at`, `updated_at` - Timestamps

## Job Lifecycle States

```
scheduled → available → executing → completed
         ↓           ↓           ↓
       (early start) (retry) (discarded/cancelled)
```

- **scheduled** - Pending execution, not yet available for workers
- **available** - Ready to execute, waiting for queue capacity
- **executing** - Currently running
- **completed** - Successfully executed
- **retryable** - Failed but retry attempts remain
- **discarded** - All retries exhausted or explicitly discarded
- **cancelled** - Intentionally stopped
- **cancelled** - Intentionally stopped (terminal)

## Creating Jobs with Options

Use `Oban.Job.new/2` to create job changesets:

```elixir
%{"email" => "user@example.com", "template" => "welcome"}
|> Oban.Job.new(
  worker: MyApp.Workers.SendEmail,
  queue: :mailers,
  priority: 1,
  max_attempts: 5,
  tags: ["email", "transactional"],
  scheduled_at: DateTime.add(DateTime.utc_now(), 300)
)
|> Oban.insert()
```

## Job Scheduling

Schedule jobs for future execution using `scheduled_at`:

```elixir
# Execute in 1 hour
scheduled_at = DateTime.add(DateTime.utc_now(), 3600, :second)

%{"report_id" => 123}
|> MyApp.Workers.GenerateReport.new(scheduled_at: scheduled_at)
|> Oban.insert()
```

## Unique Jobs

Prevent duplicate job processing with uniqueness constraints:

```elixir
defmodule MyApp.Workers.SendNotification do
  use Oban.Worker,
    queue: :notifications,
    unique: [
      period: 300,     # Uniqueness window in seconds
      fields: [:args],  # Include entire args in uniqueness check
      states: [:available, :executing]  # States triggering uniqueness
    ]

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    send_notification(args)
    :ok
  end
end
```

### Unique Configuration Options

- **`:period`** - Duration window for uniqueness (seconds)
- **`:fields`** - Aspects to compare: `:args`, `:meta`, `:queue`, `:worker` (default: `[:args, :queue, :worker]`)
- **`:keys`** - Specific argument/metadata keys to consider (requires `:fields` with `:args` or `:meta`)
- **`:states`** - Job states triggering uniqueness: `:available`, `:executing`, `:scheduled`, `:retryable`, `:completed` (default: `[:available, :executing, :scheduled]`)

### Practical Unique Examples

```elixir
# Prevent duplicate sends for same user within 1 hour
unique: [period: 3600, keys: ["user_id"], fields: [:args]]

# Prevent duplicates across any state
unique: [period: 3600, states: [:scheduled, :available, :executing, :retryable, :completed]]

# Prevent duplicates based on metadata
unique: [period: 300, keys: ["request_id"], fields: [:meta]]
```

## Priority Levels

Execute high-priority jobs first using priority levels 0-9:

```elixir
# Urgent email - execute immediately
%{"email" => "security@example.com", "subject" => "Alert"}
|> MyApp.Workers.SendEmail.new(priority: 0)
|> Oban.insert()

# Normal email - standard priority
%{"email" => "user@example.com"}
|> MyApp.Workers.SendEmail.new(priority: 5)
|> Oban.insert()

# Background task - low priority
%{"task" => "cleanup"}
|> MyApp.Workers.Cleanup.new(priority: 9)
|> Oban.insert()
```

## Job Tags

Organize jobs with categorical tags:

```elixir
# Single tag
|> MyApp.Workers.SendEmail.new(tags: ["transactional"])

# Multiple tags
|> MyApp.Workers.ProcessPayment.new(tags: ["payment", "critical", "audit"])
```

Tags enable monitoring, filtering, and organized job inspection.

## Batch Job Insertion

Insert multiple jobs efficiently:

```elixir
jobs = Enum.map(user_ids, fn user_id ->
  %{"user_id" => user_id}
  |> MyApp.Workers.SendWelcome.new()
end)

Oban.insert_all(jobs)
```

## Job Updates

Modify job fields after insertion:

```elixir
# Update priority or tags
Oban.update_job(job_id, [priority: 0, tags: ["urgent"]])

# Update arbitrary job data through args replacement
Oban.update_job(job_id, [args: %{"email" => "newemail@example.com"}])
```

## Job Metadata

Attach arbitrary metadata to jobs:

```elixir
%{"user_id" => 123}
|> MyApp.Workers.ProcessUser.new(
  meta: %{
    "request_id" => UUID.uuid4(),
    "source" => "webhook",
    "ip_address" => "192.168.1.1"
  }
)
|> Oban.insert()
```

Access metadata in worker:

```elixir
@impl Oban.Worker
def perform(%Oban.Job{args: args, meta: meta}) do
  Logger.info("Processing", request_id: meta["request_id"])
  :ok
end
```

---

[← Back to main](oban-2.20.1.md)
**Version:** 2.20.1
