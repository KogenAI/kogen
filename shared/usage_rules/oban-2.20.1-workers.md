# oban - Workers & Job Execution

## Creating Workers

Workers are modules that implement the `Oban.Worker` behaviour. Use the `use Oban.Worker` macro to define a worker with compile-time options:

```elixir
defmodule MyApp.Workers.SendNotification do
  use Oban.Worker,
    queue: :notifications,
    max_attempts: 5,
    priority: 1,
    tags: ["email", "transactional"]

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    # Implement your job logic here
    :ok
  end
end
```

### Worker Configuration Options

- **`:queue`** - Target queue name (default: `:default`)
- **`:max_attempts`** - Retry limit before discarding (default: 20)
- **`:priority`** - Execution priority 0-9 where 0 is highest (default: 0)
- **`:tags`** - Classification strings for organizing jobs (default: `[]`)
- **`:unique`** - Duplicate prevention configuration (default: `false`)
- **`:replace`** - Fields to replace upon execution (default: `[]`)

## Performing Jobs

The `perform/1` callback receives an `Oban.Job` struct containing:

- `args` - Map of job arguments
- `worker` - Module implementing the worker
- `queue` - Queue name
- `state` - Current job state
- `attempts` - Current attempt number
- `max_attempts` - Retry limit

### Return Values

Return values control job state transitions:

```elixir
# Success - job marked as completed
:ok
{:ok, result}

# Error - triggers retry if attempts remain, otherwise discards
{:error, "reason"}
raise "Any exception"

# Cancel - stops execution permanently without discard
{:cancel, "reason"}

# Snooze - reschedule for future execution
{:snooze, 300}  # Reschedule 300 seconds later
```

## Retry & Error Handling

By default, failed jobs trigger exponential backoff with retry. To customize retry behavior:

### Custom Backoff

Override the `backoff/1` callback to implement custom retry delays:

```elixir
@impl Oban.Worker
def backoff(%Oban.Job{attempt: attempt, unsaved_error: error}) do
  case error do
    %{"kind" => "raise", "reason" => "rate_limit"} -> 60  # 60 second delay
    _ -> :timer.seconds(5 * attempt + 15) + Enum.random(0..999)
  end
end
```

The `unsaved_error` map contains `:kind`, `:reason`, and `:stacktrace` for context-aware retry strategies.

### Execution Timeouts

Override `timeout/1` to set maximum execution duration in milliseconds:

```elixir
@impl Oban.Worker
def timeout(%Oban.Job{args: %{"timeout" => timeout}}) do
  timeout
end

def timeout(_), do: :timer.seconds(30)  # Default 30 seconds
```

## Job Enqueueing

Workers provide a generated `new/2` function for creating job changesets:

```elixir
# Basic enqueue
%{"email" => "user@example.com"}
|> MyApp.Workers.SendEmail.new()
|> Oban.insert()

# With custom options
%{"email" => "user@example.com"}
|> MyApp.Workers.SendEmail.new(queue: :high_priority, priority: 0)
|> Oban.insert()

# Scheduled for future execution
%{"user_id" => 123}
|> MyApp.Workers.ProcessBatch.new(scheduled_at: DateTime.add(DateTime.utc_now(), 3600))
|> Oban.insert()
```

## Error Prevention

Handle common failure scenarios in your worker:

```elixir
defmodule MyApp.Workers.FetchData do
  use Oban.Worker, queue: :fetchers, max_attempts: 3

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"url" => url}}) do
    case fetch_url(url) do
      {:ok, data} ->
        process_data(data)
        :ok
      {:error, :timeout} ->
        # Snooze instead of failing - will retry after delay
        {:snooze, 300}
      {:error, :not_found} ->
        # Don't retry for permanent errors
        {:cancel, "URL not found"}
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_url(url) do
    # Implementation with timeout handling
  end

  defp process_data(data) do
    # Processing logic
  end
end
```

## Worker Module Utilities

**`to_string/1`** - Normalizes worker module names for queries:

```elixir
Oban.Worker.to_string(MyApp.Workers.SendEmail)  # "MyApp.Workers.SendEmail"
```

**`from_string/1`** - Resolves module from string representation:

```elixir
Oban.Worker.from_string("MyApp.Workers.SendEmail")  # {:ok, MyApp.Workers.SendEmail}
```

## Advanced Patterns

### Worker with State Management

```elixir
defmodule MyApp.Workers.StatefulWorker do
  use Oban.Worker, queue: :default

  @impl Oban.Worker
  def perform(%Oban.Job{args: args, attempt: attempt, max_attempts: max}) do
    try do
      do_work(args)
      :ok
    rescue
      error ->
        if attempt < max do
          # Log attempt and prepare for retry
          {:error, inspect(error)}
        else
          # Last attempt - do cleanup before failing
          cleanup(args)
          {:error, "Max attempts reached"}
        end
    end
  end

  defp do_work(args), do: :ok
  defp cleanup(args), do: :ok
end
```

### Worker with Conditional Logic

```elixir
defmodule MyApp.Workers.ConditionalJob do
  use Oban.Worker, queue: :jobs

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"action" => action} = args}) do
    case action do
      "process" -> process_job(args)
      "validate" -> validate_job(args)
      "skip" -> {:cancel, "Action skipped"}
      _ -> {:error, "Unknown action"}
    end
  end

  defp process_job(args), do: :ok
  defp validate_job(args), do: :ok
end
```

---

[← Back to main](oban-2.20.1.md)
**Version:** 2.20.1
