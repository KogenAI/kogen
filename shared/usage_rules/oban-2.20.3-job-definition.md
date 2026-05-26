# oban - Job Definition & Worker Callbacks

## Worker Module Basics

Oban workers inherit from `use Oban.Worker` and implement the `perform/1` callback. The `use` macro accepts compile-time configuration options that apply to all jobs enqueued from that worker unless overridden at enqueue time.

```elixir
defmodule MyApp.Workers.ProcessImage do
  use Oban.Worker,
    queue: :images,
    max_attempts: 5,
    priority: 2

  @impl Oban.Worker
  def perform(job) do
    # job is an Oban.Job struct
    :ok
  end
end
```

## The perform/1 Callback

The `perform/1` function receives an `Oban.Job` struct containing all job metadata and arguments. It must return one of four result types:

- `:ok` or `{:ok, value}` — marks the job as completed successfully
- `{:error, reason}` — triggers retry logic if max_attempts not exceeded; otherwise discards
- `{:cancel, reason}` — stops retrying and marks job cancelled (no further attempts)
- `{:snooze, period}` — postpones execution by specified duration (useful for rate-limiting)

Any unhandled exception, exit, or throw is wrapped in an `Oban.PerformError` and treated as `{:error, reason}`, triggering standard retry logic.

## Worker Configuration Options

**queue** — Default queue name (string or atom, default `:default`). Overrideable at enqueue time.

**priority** — Default priority 0-9, where 0 is highest priority (default: 0). Lower numbers execute first within a queue.

**max_attempts** — Maximum retry attempts before job is discarded (default: 20). Includes the initial attempt, so value of 3 means 2 retries.

**unique** — Duplicate prevention via uniqueness constraints. Accepted options:

- `fields: [:args]` — prevent duplicate args
- `states: [:scheduled, :available]` — check only these states
- `period: 60` — uniqueness window in seconds (default: 60 \* 60)
- `replace: [:scheduled_at]` — replace these fields on conflict

Example with uniqueness:

```elixir
defmodule MyApp.Workers.SendNotification do
  use Oban.Worker,
    queue: :notifications,
    unique: [fields: [:args], period: 300]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => id}}) do
    # only one pending notification per user within 300 seconds
    :ok
  end
end
```

## Error Handling & Retry Logic

When a job fails, the system automatically wraps the error in `Oban.PerformError` containing the original `:reason`. Access the original error via the exception's `:reason` field for inspection in callbacks or logging.

**Failed jobs proceed as follows:**

1. Error is recorded with timestamp in job's `:errors` list
2. Attempt counter increments
3. If `max_attempts` not exceeded, job transitions to `:retryable` state
4. Job is rescheduled based on backoff calculation
5. If `max_attempts` exceeded, job transitions to `:discarded` state

## Backoff Customization

Override the `backoff/1` callback to customize retry delays:

```elixir
def backoff(%Oban.Job{attempt: attempt} = job) do
  # exponential backoff with cap
  min(attempt * 60, 3600)
end
```

The backoff function receives the full job struct (including `unsaved_error` for context-aware delays) and returns milliseconds to wait before retry. Default backoff uses exponential calculation with 15-second padding and jitter to prevent thundering herd.

Access `job.unsaved_error` to implement context-aware backoff — for example, extending delays when receiving rate-limit errors from an external API.

## Timeout Control

Override the `timeout/1` callback to specify maximum execution time:

```elixir
def timeout(%Oban.Job{}) do
  # 30 seconds for this worker
  30_000
end
```

Jobs exceeding the timeout are killed with `Oban.TimeoutError` and follow standard retry rules. Default timeout is 30,000 milliseconds.

## Job Arguments & Meta

Jobs receive arguments as a map in `job.args`. Store arguments as plain maps — Oban automatically encodes/decodes JSON.

```elixir
def perform(%Oban.Job{args: %{"user_id" => id, "type" => type}}) do
  # arguments are always strings keys after deserialization
  process_notification(id, type)
end
```

Access additional metadata via `job.meta` (custom map), `job.tags` (list of strings for organization), and job identification via `job.id`, `job.worker`, `job.queue`.

## Testing Worker Implementation

Workers are easily unit tested in isolation:

```elixir
test "perform handles valid arguments" do
  job = build_job(MyWorker, %{"id" => 1})
  assert perform_job(job) == :ok
end
```

See [Testing Patterns & Utilities](oban-2.20.3-testing.md) for complete testing guidance.

---

[← Back to main](oban-2.20.3.md)
**Version:** 2.20.3
