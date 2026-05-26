# oban - Testing Patterns & Utilities

## Testing Modes

Oban offers two distinct testing modes configured before application startup. Choose based on your testing strategy.

**Inline Mode** — Jobs execute immediately within the test process without database roundtrips:

```elixir
config :my_app, Oban, testing: :inline
```

Suitable for simple applications where database operations are mocked and job execution is straightforward. Jobs run synchronously in the calling process.

**Manual Mode** — Jobs insert into the database for explicit verification and execution:

```elixir
config :my_app, Oban, testing: :manual
```

Recommended for applications where job persistence and queue state matter. Provides fine-grained control over job verification and execution timing.

## Setting Up Test Helpers

Incorporate `Oban.Testing` into test modules for assertion helpers:

```elixir
defmodule MyApp.WorkerTest do
  use ExUnit.Case
  use Oban.Testing, repo: MyApp.Repo

  test "enqueues job with correct args" do
    assert_enqueued(worker: MyApp.Workers.SendEmail, args: %{"email" => "user@example.com"})
  end
end
```

For PostgreSQL schema isolation (private schemas), add the `prefix` option:

```elixir
use Oban.Testing, repo: MyApp.Repo, prefix: "private"
```

This configures assertion helpers to check the specified schema.

## Job Enqueueing Assertions

**assert_enqueued/1,2** — Verify a job matching criteria exists or will be created:

```elixir
# Simple check
assert_enqueued(worker: MyApp.Workers.SendEmail)

# With specific arguments
assert_enqueued(
  worker: MyApp.Workers.SendEmail,
  args: %{"email" => "user@example.com", "type" => "welcome"}
)

# With multiple criteria
assert_enqueued(
  worker: MyApp.Workers.SendEmail,
  queue: :mailers,
  priority: 0,
  tags: ["critical"]
)

# With timeout waiting for job to exist
assert_enqueued([worker: MyApp.Workers.SendEmail], timeout: 5000)
```

**Wildcard Matching** — Use `:_` to assert key existence without checking value:

```elixir
assert_enqueued(
  worker: MyApp.Workers.SendEmail,
  args: %{"email" => :_, "user_id" => 42}  # email must exist but any value OK
)
```

**Scheduled Time Matching** — Use `delta` for timing tolerances:

```elixir
future = DateTime.add(DateTime.utc_now(), 3600)

assert_enqueued(
  worker: MyApp.Workers.DispatchEvent,
  scheduled_at: {future, delta: 10}  # within 10 seconds
)
```

**refute_enqueued/1,2** — Verify a job with criteria does NOT exist:

```elixir
# Job should not be enqueued in this scenario
refute_enqueued(worker: MyApp.Workers.SendSpam)

# Verify specific job not present
refute_enqueued(
  worker: MyApp.Workers.SendEmail,
  args: %{"email" => "banned@example.com"}
)
```

**all_enqueued/1** — Retrieve raw list of matching jobs without assertion:

```elixir
jobs = all_enqueued(worker: MyApp.Workers.SendEmail)
assert length(jobs) == 3
```

Returns list of `Oban.Job` structs matching criteria.

## Job Execution Testing

**build_job/3** — Construct a job for testing without enqueueing:

```elixir
job = build_job(
  MyApp.Workers.SendEmail,
  %{"email" => "test@example.com"},
  queue: :mailers,
  priority: 0
)
```

Returns `Oban.Job` struct with configuration applied.

**perform_job/2,3** — Execute a job directly in test context:

```elixir
job = build_job(MyApp.Workers.ProcessData, %{"id" => 1})
result = perform_job(job)
assert result == :ok
```

Job arguments use string keys after deserialization, matching production behavior. Automatically converts atom keys to strings.

**Testing with database state:**

```elixir
test "process job with fixtures" do
  user = insert(:user)  # using factory

  job = build_job(
    MyApp.Workers.SendEmail,
    %{"user_id" => user.id}
  )

  assert perform_job(job) == :ok
  assert Repo.get(MyApp.Email, user.id).sent_at
end
```

## Dynamic Mode Switching

Override configured testing mode within specific test contexts using `with_testing_mode/2`:

```elixir
test "test with inline mode" do
  # configured as :manual globally
  with_testing_mode(:inline, fn ->
    # jobs execute immediately here
    MyApp.Workers.SendEmail.new(%{"email" => "test@example.com"})
    |> MyApp.Oban.insert()
  end)
end
```

Useful for testing different execution paths or verifying mode-specific behavior.

## Complete Worker Test Example

```elixir
defmodule MyApp.Workers.SendEmailTest do
  use ExUnit.Case
  use Oban.Testing, repo: MyApp.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(MyApp.Repo)
  end

  test "enqueues email jobs" do
    MyApp.Accounts.create_user(%{"email" => "alice@example.com"})

    assert_enqueued(
      worker: MyApp.Workers.SendWelcomeEmail,
      args: %{"email" => "alice@example.com"}
    )
  end

  test "perform sends email" do
    job = build_job(
      MyApp.Workers.SendEmail,
      %{"email" => "bob@example.com"}
    )

    assert perform_job(job) == :ok

    # verify side effects (sent to external service, DB updated, etc.)
    assert MyApp.EmailLog.exists?("bob@example.com")
  end

  test "retry on transient failure" do
    job = build_job(MyApp.Workers.SendEmail, %{"email" => "fail@example.com"})

    # first attempt fails
    result = perform_job(job)
    assert {:error, "Connection timeout"} = result

    # job records error and is available for retry
    assert job.attempt == 1
  end
end
```

## Testing Queue Operations

Test queue control in manual mode:

```elixir
test "drains queue" do
  # enqueue multiple jobs
  for i <- 1..5 do
    MyApp.Workers.ProcessItem.new(%{"id" => i})
    |> MyApp.Oban.insert()
  end

  {:ok, jobs} = Oban.drain_queue(MyApp.Oban, :default)
  assert length(jobs) == 5
end
```

---

[← Back to main](oban-2.20.3.md)
**Version:** 2.20.3
