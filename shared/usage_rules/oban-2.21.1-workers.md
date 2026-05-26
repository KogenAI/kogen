# oban - Workers & Job Execution

## Worker Basics

Every Oban worker is a module implementing the `Oban.Worker` behavior with a required `perform/1` callback that receives an `Oban.Job` struct:

```elixir
defmodule MyApp.ProcessDataWorker do
  use Oban.Worker, queue: :default

  def perform(%Oban.Job{args: %{"id" => id}}) do
    data = fetch_data(id)
    process_data(data)
    :ok
  end
end
```

## Worker Options

Configure workers via `use Oban.Worker`:

**`:queue`** — Target queue name. Default: `:default`.

**`:max_attempts`** — Retry limit before job discarding. Default: 20. Set to 1 for no retries:

```elixir
use Oban.Worker, queue: :critical, max_attempts: 1
```

**`:priority`** — Default job priority 0-9 (0 = highest, 9 = lowest):

```elixir
use Oban.Worker, priority: 2
```

**`:tags`** — Associated metadata strings for organization:

```elixir
use Oban.Worker, tags: ["daily", "reports"]
```

**`:unique`** — Duplicate prevention configuration:

```elixir
use Oban.Worker, unique: [period: 300, fields: [:worker]]
```

**`:replace`** — Field replacement rules on job execution (Pro feature).

## The perform/1 Callback

The `perform/1` function controls job outcome through its return value:

```elixir
def perform(%Oban.Job{args: %{"email" => email}}) do
  case send_email(email) do
    {:ok, _} -> :ok                          # Success
    {:error, reason} -> {:error, reason}     # Retry or discard after max_attempts
    {:cancel, _} = cancel -> cancel           # Stop permanently without retry
    {:snooze, period} -> {:snooze, period}   # Postpone execution
  end
end
```

**Return Values:**

- **`:ok`** — Job succeeds immediately
- **`{:error, reason}`** — Job marked retryable; retried according to backoff strategy
- **`{:cancel, reason}`** — Job cancelled permanently without further retries
- **`{:snooze, period}`** — Job rescheduled after delay (seconds or tuple like `{5, :minutes}`)

## Job Enqueuing

Workers auto-generate a `new/2` function for creating changesets:

```elixir
%{email: "user@example.com", body: "Hello"}
|> MyApp.EmailWorker.new()
|> Oban.insert()

# With options
%{user_id: 123}
|> MyApp.ProcessWorker.new(priority: 2, schedule_in: {1, :hour})
|> Oban.insert()
```

## Advanced Callbacks

### Custom Backoff

Override `backoff/1` to control retry delay calculation:

```elixir
def backoff(%Job{attempt: attempt}) do
  # Linear backoff: 300s, 600s, 900s...
  attempt * 300
end
```

Useful for rate-limiting scenarios where exponential backoff is inappropriate.

### Execution Timeout

Implement `timeout/1` to set per-job millisecond limits:

```elixir
def timeout(%Job{args: %{"type" => "heavy"}}), do: 30_000  # 30 seconds
def timeout(%Job{}), do: 5_000                              # 5 seconds
```

Without explicit timeout, Oban uses a global default.

### Snoozing vs Failures

Snoozing differs from retryable failures:

- Failures increment `attempt` and may trigger discard after `max_attempts`
- Snoozing increments `max_attempts` to preserve retry budget while postponing work

Use snoozing for temporary conditions (rate limits, resource contention) where you want to defer work without consuming retries.

## Error Handling Patterns

```elixir
defmodule MyApp.RobustWorker do
  use Oban.Worker

  def perform(%Oban.Job{args: args, attempt: attempt}) do
    case do_work(args) do
      {:ok, result} ->
        log_success(result)
        :ok

      {:error, :rate_limited} when attempt < 10 ->
        # Snooze for exponential backoff on rate limits
        {:snooze, min(2 ** attempt, 3600)}

      {:error, :not_found} ->
        # Permanent failure, no retry
        {:cancel, "Resource not found"}

      {:error, reason} ->
        # Transient error, will retry
        {:error, reason}
    end
  end
end
```

## Job Arguments

Job arguments are always maps and must be JSON-serializable:

```elixir
# Valid
MyWorker.new(%{"user_id" => 123, "tags" => ["urgent"]})

# Invalid (atoms not serializable)
MyWorker.new(%{user_id: 123})  # Will fail at insertion

# Convert as needed
args = %{user_id: 123} |> Enum.into(%{"user_id" => elem})
MyWorker.new(args)
```

---

[← Back to main](oban-2.21.1.md)  
**Version:** 2.21.1
