# oban - Job Management & Lifecycle

## Job Structure

Jobs flow through states representing their lifecycle: `suspended` → `scheduled` → `available` → `executing` → (completed, retryable, cancelled, or discarded).

The `Oban.Job` struct contains:

- **`id`** — Unique job identifier
- **`args`** — JSON-serializable map of arguments passed to the worker
- **`worker`** — Worker module name (atom)
- **`queue`** — Queue name (atom)
- **`state`** — Current state (`"suspended"`, `"scheduled"`, `"available"`, `"executing"`, `"completed"`, `"retryable"`, `"cancelled"`, `"discarded"`)
- **`priority`** — Numeric priority 0-9 (0 = highest)
- **`attempt`** — Current attempt number
- **`max_attempts`** — Total retry limit
- **`errors`** — Array of failure records with timestamps and messages
- **`tags`** — Metadata strings for organization
- **`unique`** — Unique constraint configuration
- **`inserted_at`** / **`updated_at`** — Timestamps
- **`scheduled_at`** — When job should execute (future date for scheduled jobs)

## Job States

**`suspended`** — Job not yet ready. Used internally during unique constraint handling.

**`scheduled`** — Job waiting for future execution. `scheduled_at` timestamp determines when it becomes available.

**`available`** — Ready for execution by a waiting worker.

**`executing`** — Currently running. "Orphaned" if the process crashes before completion.

**`completed`** — Successfully executed. Jobs remain in the database for metrics.

**`retryable`** — Failed with attempts remaining. Will be retried according to backoff.

**`cancelled`** — Permanently stopped via explicit cancellation request.

**`discarded`** — Failed after exhausting all retry attempts.

## Inserting Jobs

Single job insertion with automatic uniqueness handling:

```elixir
%{email: "user@example.com"}
|> MyApp.EmailWorker.new()
|> Oban.insert()

# With result tuple
case Oban.insert(job) do
  {:ok, job} -> handle_success(job)
  {:error, changeset} -> handle_error(changeset)
end
```

Batch insertion for performance:

```elixir
jobs = Enum.map(emails, &MyApp.EmailWorker.new/1)
Oban.insert_all(jobs)
```

Transactional insertion alongside other database operations:

```elixir
Repo.transaction(fn ->
  user = create_user(attrs)
  MyApp.WelcomeEmailWorker.new(%{"user_id" => user.id})
  |> Oban.insert()
  user
end)
```

## Job Scheduling

Schedule jobs for future execution:

```elixir
# Execute in 5 minutes
MyApp.ReportWorker.new(%{id: 123}, schedule_in: {5, :minutes})
|> Oban.insert()

# Execute at specific time (Unix timestamp)
MyApp.ReportWorker.new(%{}, schedule_in: DateTime.utc_now() |> DateTime.add(3600))
|> Oban.insert()
```

## Unique Jobs

Prevent duplicate jobs using uniqueness constraints:

```elixir
# One job per minute per user
MyApp.ProcessUserWorker.new(
  %{"user_id" => 123},
  unique: [period: 60, fields: [:args, :worker]]
)
|> Oban.insert()

# Alternative: hash-based uniqueness
MyApp.SendNotificationWorker.new(
  %{"user_id" => 123},
  unique: [period: 300, keys: [:user_id]]
)
|> Oban.insert()
```

Uniqueness options:

- **`period`** — Seconds the constraint applies (300 = 5 minutes)
- **`fields`** — Include these fields in uniqueness check: `:args`, `:worker`, `:queue`
- **`keys`** — Specific argument keys for fine-grained uniqueness
- **`states`** — Only consider these states when checking (default: all non-terminal states)

## Cancelling Jobs

Cancel a job before or during execution:

```elixir
# Cancel specific job
Oban.cancel_job(job.id)

# Cancel all jobs matching criteria
Oban.cancel_all_jobs(Oban.Job, where: [worker: "MyApp.SlowWorker"])
```

Cancelled jobs move to the `"cancelled"` state and emit telemetry events for monitoring.

## Retrying Jobs

Manually retry failed jobs:

```elixir
# Retry specific job (resets attempt counter)
Oban.retry_job(job)

# Retry all jobs in a queue
Oban.retry_all_jobs(Oban.Job, where: [queue: "mailers"])
```

Retried jobs move to `"available"` and increment retry counters.

## Updating Jobs

Modify job attributes before execution:

```elixir
job
|> Ecto.Changeset.change(%{priority: 5, tags: ["updated"]})
|> Oban.update_job()
```

Updatable fields: priority, tags, max_attempts (limited by current attempts), and certain state transitions.

## Deleting Jobs

Permanently remove jobs from the database:

```elixir
# Delete specific job
Oban.delete_job(job)

# Delete all jobs from a queue
Oban.delete_all_jobs(Oban.Job, where: [queue: "background"])
```

Use deletion to clean up old completed jobs and reduce database size.

## Job Errors

Failed jobs store error details in the `errors` array:

```elixir
# In worker
def perform(%Job{}) do
  {:error, "Database connection timeout"}
end

# Inspect errors
job.errors |> Enum.each(fn %{"attempt" => a, "error" => e} ->
  IO.inspect({a, e})
end)
```

Errors accumulate per job, preserving execution history for debugging and monitoring.

---

[← Back to main](oban-2.21.1.md)  
**Version:** 2.21.1
