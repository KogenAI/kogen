# oban - Advanced Patterns

## Job Cancellation

Stop jobs from executing or mid-execution:

```elixir
# Cancel by job ID
Oban.cancel_job(Oban, job_id)

# Cancel by worker module (all jobs)
Oban.cancel_job(Oban, MyApp.Workers.SendEmail)
```

**In worker**, return `{:cancel, reason}` to prevent retries:

```elixir
@impl Oban.Worker
def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
  case Repo.get(User, user_id) do
    nil ->
      # User deleted - don't retry
      {:cancel, "User no longer exists"}

    user ->
      do_work(user)
  end
end
```

## Unique Jobs

Prevent duplicate processing within a time window:

### Basic Uniqueness

```elixir
defmodule MyApp.Workers.SendNotification do
  use Oban.Worker,
    queue: :notifications,
    unique: [
      period: 300,  # 5 minutes
      fields: [:args]
    ]

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    send_notification(args)
    :ok
  end
end
```

### Unique by Specific Fields

```elixir
unique: [
  period: 3600,
  keys: ["user_id"],  # Only this key matters
  fields: [:args]
]
```

### Unique Across Multiple Fields

```elixir
unique: [
  period: 300,
  fields: [:args, :meta],  # Consider both args and meta
  keys: ["action", "request_id"]
]
```

## Job Replacement

Replace job fields on execution (useful for scheduled jobs):

```elixir
defmodule MyApp.Workers.ReportGenerator do
  use Oban.Worker,
    queue: :reports,
    replace: [:priority]  # Replace priority when executing

  @impl Oban.Worker
  def perform(%Oban.Job{args: args, priority: _}) do
    # Priority can be overridden at execution time
    generate_report(args)
    :ok
  end
end
```

## Batch Processing

Process multiple items efficiently:

```elixir
defmodule MyApp.Workers.ProcessBatch do
  use Oban.Worker, queue: :batch

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_ids" => user_ids}}) do
    user_ids
    |> Repo.all(User)
    |> process_users()
    :ok
  end

  defp process_users(users) do
    Enum.each(users, &send_email/1)
  end

  defp send_email(user) do
    # Email logic
  end
end

# Enqueue batch
Enum.chunk_every(1..1000, 100)
|> Enum.each(fn chunk ->
  %{"user_ids" => chunk}
  |> MyApp.Workers.ProcessBatch.new()
  |> Oban.insert()
end)
```

## Custom Backoff Strategies

Implement smart retry delays:

```elixir
defmodule MyApp.Workers.FetchExternalData do
  use Oban.Worker, queue: :fetchers

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt, unsaved_error: error}) do
    case error do
      # Rate limit - exponential backoff
      %{"reason" => "rate_limit"} ->
        :timer.seconds(60 * (2 ** attempt))

      # Server error - shorter backoff
      %{"kind" => "raise", "reason" => "HTTPError"} ->
        :timer.seconds(30 * attempt)

      # Network error - jittered exponential
      %{"reason" => "timeout"} ->
        base = :timer.seconds(5 * attempt)
        jitter = Enum.random(0..999)
        base + jitter

      # Default - exponential with jitter
      _ ->
        :timer.seconds(5 * attempt + 15) + Enum.random(0..999)
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"url" => url}}) do
    case fetch_data(url) do
      {:ok, data} -> :ok
      {:error, :rate_limit} -> {:error, "rate_limit"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_data(url) do
    # Implementation
  end
end
```

## Dynamic Timeouts

Set execution timeouts based on job attributes:

```elixir
defmodule MyApp.Workers.ProcessVideo do
  use Oban.Worker, queue: :video_processing

  @impl Oban.Worker
  def timeout(%Oban.Job{args: %{"duration_seconds" => duration}}) do
    # Timeout = 30 seconds + 2 seconds per minute of video
    30_000 + (duration * 2000)
  end

  def timeout(_), do: 180_000  # Default 3 minutes

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"video_id" => id}}) do
    Video.process(id)
    :ok
  end
end
```

## Job Registry & Lookup

Locate running jobs and access their state:

```elixir
# Get process info for a specific queue producer
{:ok, pid} = Oban.Registry.whereis(Oban, {:producer, :mailers})

# Check if a queue is running
case Oban.Registry.whereis(Oban, {:producer, :critical}) do
  {:ok, pid} -> {:ok, "Queue running"}
  :error -> {:error, "Queue not running"}
end

# Select multiple processes
Oban.Registry.select([
  {{:"$1", :"$2", :"$3"}, [], [{:*, :"$2", :"$3"}]}
])
```

## Plugin Development

Create custom plugins for extended functionality:

```elixir
defmodule MyApp.Plugins.QueueScaler do
  use GenServer
  require Logger

  @behaviour Oban.Plugin

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl Oban.Plugin
  def validate(opts) do
    case Keyword.fetch(opts, :conf) do
      {:ok, _} -> :ok
      :error -> {:error, "missing :conf"}
    end
  end

  def init(opts) do
    conf = Keyword.fetch!(opts, :conf)

    schedule_check()

    {:ok, %{conf: conf}}
  end

  def handle_info(:check_load, state) do
    # Check queue load and scale accordingly
    scale_queues()

    schedule_check()
    {:noreply, state}
  end

  defp scale_queues() do
    # Implement scaling logic
  end

  defp schedule_check() do
    Process.send_after(self(), :check_load, 60_000)
  end
end

# Add to config
config :my_app, Oban,
  plugins: [
    {MyApp.Plugins.QueueScaler, []}
  ]
```

## Job Chain Patterns

Coordinate dependent jobs:

```elixir
defmodule MyApp.Workers.ProcessOrder do
  use Oban.Worker, queue: :orders

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"order_id" => order_id}}) do
    order = Repo.get(Order, order_id)

    # Enqueue dependent jobs
    case process_payment(order) do
      :ok ->
        # Only enqueue next step if payment succeeded
        schedule_fulfillment(order_id)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp process_payment(order) do
    # Payment processing
  end

  defp schedule_fulfillment(order_id) do
    %{"order_id" => order_id}
    |> MyApp.Workers.FulfillOrder.new(
      scheduled_at: DateTime.add(DateTime.utc_now(), 3600)
    )
    |> Oban.insert()
  end
end
```

## Worker with Notifications

Notify other processes when jobs complete:

```elixir
defmodule MyApp.Workers.ProcessData do
  use Oban.Worker, queue: :processing

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"data_id" => data_id}} = job) do
    result = process_data(data_id)

    # Notify subscribers
    Oban.Notifier.notify(
      Oban,
      :data_processing,
      %{
        data_id: data_id,
        status: "completed",
        result: result,
        job_id: job.id
      }
    )

    :ok
  end

  defp process_data(data_id) do
    # Processing logic
  end
end

# Listen for notifications
Oban.Notifier.listen(Oban, :data_processing)

# Receive messages
receive do
  {:notification, :data_processing, payload} ->
    Logger.info("Data processing complete", payload)
end
```

## Testing Complex Workers

```elixir
defmodule MyApp.Workers.ComplexJobTest do
  use ExUnit.Case

  import Oban.Testing

  test "complex job with state transitions" do
    # Setup
    job_id = setup_job()

    # Execute with specific args
    result = perform_job(MyApp.Workers.ComplexJob, %{"job_id" => job_id})

    assert result == :ok

    # Verify side effects
    assert_job_completed(job_id)
  end

  test "job handles partial failures" do
    result = perform_job(
      MyApp.Workers.ComplexJob,
      %{"fail_at" => "step_2"}
    )

    assert {:error, "step_2 failed"} = result
  end

  defp setup_job() do
    # Test setup
  end

  defp assert_job_completed(job_id) do
    # Assertions
  end
end
```

---

[← Back to main](oban-2.20.1.md)
**Version:** 2.20.1
