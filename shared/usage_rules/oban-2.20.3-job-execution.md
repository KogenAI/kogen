# oban - Job Execution & Error Handling

## Job Lifecycle States

Jobs transition through seven distinct states during their lifetime:

1. **`:scheduled`** — Future-dated jobs waiting for their scheduled time. Transition to `:available` when scheduled time arrives (via staging process).

2. **`:available`** — Ready for immediate execution. Queue producers fetch available jobs and transition them to `:executing`.

3. **`:executing`** — Currently running in a job execution process. On success, transitions to `:completed`. On failure, transitions to `:retryable` or `:discarded` based on attempt count.

4. **`:retryable`** — Failed but retry attempts remain. Job is held until backoff period expires, then transitions back to `:available` for retry.

5. **`:completed`** — Successfully finished. Terminal state; no further transitions.

6. **`:cancelled`** — Intentionally stopped via `cancel_job/2`. Terminal state; retrying not possible.

7. **`:discarded`** — Exhausted all retry attempts or explicitly discarded. Terminal state; job will not execute again unless explicitly retried.

Job data persists indefinitely in these terminal states, enabling historical inspection and retry capability.

## Error Handling

When a job's `perform/1` callback returns `{:error, reason}` or raises an unhandled exception, Oban records the error and decides on retry eligibility.

**Error Recording:**

```elixir
def perform(%Oban.Job{}) do
  {:error, "Connection timeout"}
end
```

The error is appended to the job's `:errors` list with a timestamp. The full error (with stacktrace for exceptions) is stored for later inspection.

**Retry Decision:**

If `max_attempts` has not been reached, the job transitions to `:retryable` and is rescheduled after a backoff delay. If all attempts are exhausted, the job transitions to `:discarded`.

## Accessing Errors in Workers

Failed jobs are re-executed with error information available via the job struct:

```elixir
def perform(%Oban.Job{unsaved_error: error} = job) do
  case error do
    nil ->
      # First attempt, no prior error
      perform_work()

    {:error, reason} ->
      # Retry attempt; access reason for context-aware handling
      handle_retry(reason)

    _ ->
      # Exception case
      {:error, "Unexpected error"}
  end
end
```

The `unsaved_error` field contains the previous attempt's error for context-aware handling.

## Backoff Strategies

Backoff customization controls retry delay timing. Default behavior uses exponential backoff with jitter to prevent thundering herd.

**Custom Backoff with Exponential Growth:**

```elixir
def backoff(%Oban.Job{attempt: attempt}) do
  # exponential: 1min, 2min, 4min, 8min, ... capped at 1 hour
  min(attempt * 60 * 1000, :timer.hours(1))
end
```

**Context-Aware Backoff:**

```elixir
def backoff(%Oban.Job{attempt: attempt, unsaved_error: error}) do
  case error do
    {:error, "Rate limit"} ->
      # extend delay when rate-limited
      attempt * 300 * 1000

    {:error, "Temporary failure"} ->
      # shorter backoff for transient errors
      attempt * 5 * 1000

    _ ->
      # default exponential
      attempt * 60 * 1000
  end
end
```

The function receives the full job struct and returns milliseconds to wait before retry. Jitter is automatically applied to prevent synchronized retries across job instances.

## Timeout Handling

Jobs exceeding their configured timeout are killed with `Oban.TimeoutError`. The error is recorded and follows standard retry logic.

**Custom Timeouts:**

```elixir
defmodule MyApp.Workers.LongRunningProcess do
  use Oban.Worker

  def timeout(%Oban.Job{args: %{"type" => "heavy"}}) do
    # allow 5 minutes for heavy processing
    :timer.minutes(5)
  end

  def timeout(%Oban.Job{}), do: 30_000  # default 30 seconds

  @impl Oban.Worker
  def perform(job) do
    # must complete within timeout limit
    :ok
  end
end
```

## Job Cancellation

Cancel jobs via `Oban.cancel_job/2` to immediately transition them to `:cancelled` state:

```elixir
Oban.cancel_job(MyApp.Oban, job_id)
```

Cancelled jobs:

- Do not retry if currently executing
- Do not execute if scheduled
- Are treated as terminal state

## Snoozed Jobs

Return `{:snooze, duration_ms}` from `perform/1` to postpone execution:

```elixir
def perform(%Oban.Job{attempt: attempt}) do
  case fetch_external_data() do
    {:ok, data} -> process(data)
    :not_ready -> {:snooze, 30_000}  # retry in 30 seconds
    {:error, reason} -> {:error, reason}  # standard retry
  end
end
```

Snoozed jobs are rescheduled immediately without counting as a failure, preserving the attempt counter. Useful for polling external systems or handling temporary unavailability.

## Exception Handling Best Practices

Wrap external API calls in error handling:

```elixir
def perform(%Oban.Job{args: %{"url" => url}}) do
  case HTTPClient.get(url) do
    {:ok, response} -> process_response(response)
    {:error, :timeout} -> {:error, "Request timeout"}
    {:error, reason} -> {:error, inspect(reason)}
  end
end
```

Avoid letting exceptions bubble up; explicitly return `{:error, reason}` for better error tracking and logging.

## Job Completion

Successfully completed jobs transition to `:completed` state and persist indefinitely:

```elixir
def perform(job) do
  process_work()
  :ok  # or {:ok, return_value}
end
```

The optional return value is stored in the job's `:result` field for historical reference.

## Pruning Old Jobs

Configure the Pruner plugin to delete completed/cancelled/discarded jobs after retention period:

```elixir
config :my_app, Oban,
  plugins: [
    {Oban.Plugins.Pruner, interval: :timer.hours(1), retention: :timer.days(7)}
  ]
```

Pruned jobs are permanently deleted after the retention period; adjust based on audit/compliance requirements.

---

[← Back to main](oban-2.20.3.md)
**Version:** 2.20.3
