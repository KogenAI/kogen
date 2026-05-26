# oban - Testing Patterns & Helpers

## Testing Modes

Oban provides two distinct testing modes to control job execution behavior:

### Inline Mode

Jobs execute immediately within the calling process without database writes. Ideal for simpler applications with minimal job interactions:

```elixir
# config/test.exs
config :my_app, Oban, testing: :inline
```

In inline mode:

- Jobs execute synchronously in the calling process
- No database roundtrip
- Perfect for testing simple job logic
- Cannot inspect queued jobs
- Cannot test ordering or concurrency

```elixir
test "inline mode executes jobs immediately" do
  result = MyApp.EmailWorker.new(%{email: "test@example.com"}) |> Oban.insert()

  # Job has already executed
  assert email_sent?()
end
```

### Manual Mode

Jobs insert into the database for explicit test-controlled execution. Better for complex scenarios:

```elixir
# config/test.exs
config :my_app, Oban, testing: :manual
```

In manual mode:

- Jobs insert to database without automatic execution
- Tests control when and how jobs execute
- Can verify job state, ordering, retries
- Database schema required
- More realistic testing of job interactions

```elixir
test "manual mode allows job inspection" do
  MyApp.ReportWorker.new(%{id: 123}) |> Oban.insert()

  # Job is queued but not executed
  assert {:ok, job} = assert_enqueued(worker: MyApp.ReportWorker, args: %{"id" => "123"})

  # Execute when ready
  :ok = Oban.drain_queue(:default)

  # Verify execution
  assert report_generated?(123)
end
```

## Testing Helpers

Use `Oban.Testing` module with ExUnit:

```elixir
defmodule MyApp.MyTest do
  use ExUnit.Case
  use Oban.Testing, repo: MyApp.Repo

  # Now have access to testing helpers
end
```

### Dynamic Mode Switching

Override configured mode for specific tests:

```elixir
test "job processes with retry logic" do
  Oban.Testing.with_testing_mode(:manual, fn ->
    MyApp.FailableWorker.new(%{id: 1}) |> Oban.insert()

    # Inspect job state
    job = Oban.Job |> where([j], j.worker == "MyApp.FailableWorker") |> MyApp.Repo.one()
    assert job.state == "available"
  end)
end
```

## Draining Queues

Synchronously execute all jobs in a queue:

```elixir
defmodule MyApp.JobProcessingTest do
  use ExUnit.Case

  test "all queued jobs execute" do
    # Insert multiple jobs
    Enum.each(1..5, fn id ->
      MyApp.ProcessWorker.new(%{id: id}) |> Oban.insert()
    end)

    # Execute all
    Oban.drain_queue(:default)

    # Verify all processed
    assert MyApp.Repo.aggregate(MyApp.ProcessedRecord, :count) == 5
  end
end
```

Drain options:

**`:with_limit`** — Process maximum N jobs per drain iteration:

```elixir
# Process 5 jobs at a time
Oban.drain_queue(:default, with_limit: 5)
```

**`:with_recursion`** — Continue draining if jobs spawn new jobs:

```elixir
# Handle job chains
Oban.drain_queue(:default, with_recursion: true)
```

**`:with_scheduled`** — Include scheduled jobs:

```elixir
MyApp.ReportWorker.new(%{}) |> Oban.insert(schedule_in: {1, :hour})
Oban.drain_queue(:default, with_scheduled: true)
```

**`:with_safety`** — Control exception handling behavior:

```elixir
# Reraise exceptions
Oban.drain_queue(:default, with_safety: false)

# Catch exceptions (default)
Oban.drain_queue(:default, with_safety: true)
```

## Assertion Helpers

Verify jobs were enqueued as expected:

```elixir
test "assert enqueued" do
  MyApp.EmailWorker.new(%{email: "user@example.com"}) |> Oban.insert()

  # Verify job exists
  assert_enqueued(worker: MyApp.EmailWorker)
  assert_enqueued(worker: MyApp.EmailWorker, args: %{"email" => "user@example.com"})

  # Get the job
  {:ok, job} = assert_enqueued(worker: MyApp.EmailWorker)
  assert job.state == "available"
end
```

Assert job not enqueued:

```elixir
test "assert not enqueued" do
  refute_enqueued(worker: MyApp.DeletedUserWorker)
end
```

## PostgreSQL Schema Isolation

For PostgreSQL-backed tests with schema isolation:

```elixir
defmodule MyApp.MyTest do
  use ExUnit.Case
  use Oban.Testing, repo: MyApp.Repo, prefix: "private"
end
```

This isolates Oban's job table to the specified schema during tests.

## Testing Retries

Verify retry logic:

```elixir
defmodule MyApp.RetryTest do
  use ExUnit.Case
  use Oban.Testing, repo: MyApp.Repo

  test "job retries on transient failure" do
    Oban.Testing.with_testing_mode(:manual, fn ->
      job = MyApp.UnreliableWorker.new(%{attempt: 1}) |> Oban.insert!()

      # Simulate first execution failure
      {:error, "Temporary error"} = MyApp.UnreliableWorker.perform(job)

      # Verify job is retryable
      updated_job = MyApp.Repo.reload(job)
      assert updated_job.state == "retryable"
      assert updated_job.attempt == 1
    end)
  end
end
```

## Testing CRON Jobs

Include scheduled jobs when testing cron:

```elixir
test "daily cron job executes" do
  MyApp.DailyReportWorker.new(%{}) |> Oban.insert(schedule_in: {5, :minutes})

  # Include scheduled jobs in drain
  Oban.drain_queue(:default, with_scheduled: true)

  assert report_generated?()
end
```

## Common Test Patterns

**Isolated worker testing:**

```elixir
test "worker processes args correctly" do
  job = %Oban.Job{args: %{"user_id" => 123}, attempt: 1}
  assert :ok = MyApp.ProcessUserWorker.perform(job)
end
```

**Job state verification:**

```elixir
test "failed jobs move to retryable state" do
  Oban.Testing.with_testing_mode(:manual, fn ->
    MyApp.FailingWorker.new(%{}) |> Oban.insert()

    # Manually execute
    job = Oban.Job |> where([j], j.worker == "MyApp.FailingWorker") |> MyApp.Repo.one()
    {:error, _} = MyApp.FailingWorker.perform(job)

    # Verify state change
    updated = MyApp.Repo.reload(job)
    assert updated.state == "retryable"
  end)
end
```

---

[← Back to main](oban-2.21.1.md)  
**Version:** 2.21.1
