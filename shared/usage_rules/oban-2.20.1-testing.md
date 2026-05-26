# oban - Testing & Assertions

## Test Setup

Import Oban testing utilities in your test file:

```elixir
defmodule MyApp.Workers.SendEmailTest do
  use ExUnit.Case

  import Oban.Testing, only: [assert_enqueued: 2, refute_enqueued: 2]

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(MyApp.Repo)
  end

  test "emails are enqueued" do
    # Your test code
  end
end
```

For namespaced databases using Postgres schemas:

```elixir
use Oban.Testing, repo: MyApp.Repo, prefix: "business"
```

## Job Assertions

### Assert Enqueued

Verify a job was enqueued with specific arguments:

```elixir
test "user signup enqueues welcome email" do
  user = create_user(email: "test@example.com")

  assert_enqueued(worker: MyApp.Workers.SendWelcome, args: %{"user_id" => user.id})
end
```

Matches jobs only if ALL provided arguments match:

```elixir
# All these must match
assert_enqueued(
  worker: MyApp.Workers.ProcessPayment,
  args: %{"order_id" => 123},
  queue: :payments,
  priority: 0
)
```

With timeout to wait for async enqueueing:

```elixir
# Wait up to 500ms for job to be enqueued
assert_enqueued(
  [worker: MyApp.Workers.SendEmail, args: %{"email" => "test@example.com"}],
  500
)
```

### Refute Enqueued

Verify a job was NOT enqueued:

```elixir
test "invalid users don't get welcome email" do
  create_invalid_user(email: "invalid@example.com")

  refute_enqueued(worker: MyApp.Workers.SendWelcome)
end
```

### List All Enqueued

Retrieve all jobs matching criteria:

```elixir
jobs = Oban.Testing.all_enqueued(worker: MyApp.Workers.SendEmail)

# Most recently enqueued first
assert length(jobs) == 2
assert [first_job | _] = jobs
```

## Building & Executing Jobs

### Build Job

Construct a job for testing without inserting:

```elixir
job = Oban.Testing.build_job(MyApp.Workers.SendEmail, %{"email" => "test@example.com"})

assert job.worker == "MyApp.Workers.SendEmail"
assert job.args == %{"email" => "test@example.com"}
```

With options:

```elixir
job = Oban.Testing.build_job(
  MyApp.Workers.SendEmail,
  %{"email" => "test@example.com"},
  queue: :mailers,
  priority: 1
)
```

### Perform Job

Execute a job and verify result:

```elixir
defmodule MyApp.Workers.SendEmailTest do
  use ExUnit.Case

  test "job executes successfully" do
    assert :ok == Oban.Testing.perform_job(
      MyApp.Workers.SendEmail,
      %{"email" => "test@example.com"}
    )
  end

  test "job handles errors" do
    assert {:error, _} = Oban.Testing.perform_job(
      MyApp.Workers.SendEmail,
      %{"email" => "invalid"}
    )
  end
end
```

Perform pre-built job:

```elixir
job = Oban.Testing.build_job(MyApp.Workers.SendEmail, %{"email" => "test@example.com"})
result = Oban.Testing.perform_job(job)
assert result == :ok
```

**Important**: Arguments are automatically stringified to prevent matching issues:

```elixir
# Both match correctly
Oban.Testing.perform_job(MyApp.Worker, %{user_id: 123})
Oban.Testing.perform_job(MyApp.Worker, %{"user_id" => 123})
```

## Testing Modes

### Manual Mode (Default in Tests)

Jobs are enqueued but NOT executed:

```elixir
config :my_app, Oban,
  testing: :manual
```

Manually execute jobs with `perform_job` or `drain_queue`:

```elixir
test "manual mode" do
  %{"data" => "value"}
  |> MyApp.Workers.Process.new()
  |> Oban.insert()

  # Job is enqueued but not executed
  assert_enqueued(worker: MyApp.Workers.Process)

  # Execute manually
  Oban.Testing.perform_job(MyApp.Workers.Process, %{"data" => "value"})
end
```

### Inline Mode

Jobs execute immediately upon insertion:

```elixir
config :my_app, Oban,
  testing: :inline
```

Useful for simple integration tests:

```elixir
test "inline mode" do
  # Job executes immediately
  %{"email" => "test@example.com"}
  |> MyApp.Workers.SendEmail.new()
  |> Oban.insert()

  # Email already sent
  assert email_sent_to("test@example.com")
end
```

### Disabled Mode

Jobs are enqueued but not executed:

```elixir
config :my_app, Oban,
  testing: :disabled  # Also default if not in test env
```

## Testing Mode Switching

Change testing mode mid-test:

```elixir
test "switching modes" do
  # Use manual by default
  assert_enqueued(worker: MyApp.Workers.Process)

  # Switch to inline temporarily
  Oban.Testing.with_testing_mode(Oban, :inline, fn ->
    # Jobs execute immediately within this block
    job = Oban.Testing.perform_job(MyApp.Workers.SendEmail, %{})
  end)

  # Back to manual mode
end
```

## Drain Queue

Synchronously execute jobs in tests:

```elixir
test "drain queue" do
  # Enqueue multiple jobs
  enqueue_jobs(5)

  # Execute all available jobs
  Oban.drain_queue(Oban, queue: :default)

  # All jobs processed
  assert jobs_completed() == 5
end
```

Options:

```elixir
# Execute only scheduled jobs that have become available
Oban.drain_queue(Oban, queue: :default, with_scheduled: true)

# Execute first 3 jobs only
Oban.drain_queue(Oban, queue: :default, limit: 3)

# Safe mode (explicit safety confirmation)
Oban.drain_queue(Oban, queue: :default, safe: true)
```

## Complete Testing Example

```elixir
defmodule MyApp.Workers.ProcessOrderTest do
  use ExUnit.Case, async: true

  import Oban.Testing

  alias MyApp.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  test "creates payment job on order processing" do
    order = create_order(amount: 100)

    MyApp.Workers.ProcessOrder.new(%{"order_id" => order.id})
    |> Oban.insert()

    assert_enqueued(worker: MyApp.Workers.ProcessPayment, args: %{"order_id" => order.id})
  end

  test "handles missing orders gracefully" do
    result = Oban.Testing.perform_job(
      MyApp.Workers.ProcessOrder,
      %{"order_id" => 999}
    )

    assert {:cancel, _} = result
  end

  test "retries on temporary failures" do
    job = Oban.Testing.build_job(
      MyApp.Workers.FetchData,
      %{"url" => "http://example.com"}
    )

    assert {:error, _} = Oban.Testing.perform_job(job)
  end

  defp create_order(attrs) do
    Repo.insert!(%MyApp.Order{amount: attrs[:amount]})
  end
end
```

---

[← Back to main](oban-2.20.1.md)
**Version:** 2.20.1
