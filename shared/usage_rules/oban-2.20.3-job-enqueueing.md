# oban - Job Enqueueing & Configuration

## Enqueueing Jobs

Jobs are enqueued by building a job struct via the worker's `new/2` function, then inserting via `Oban.insert/3` or `Oban.insert_all/3`.

**Single Job:**

```elixir
%{"user_id" => 42}
|> MyApp.Workers.ProcessUser.new()
|> MyApp.Oban.insert()
```

**Multiple Jobs:**

```elixir
jobs = [
  MyApp.Workers.SendEmail.new(%{"email" => "alice@example.com"}),
  MyApp.Workers.SendEmail.new(%{"email" => "bob@example.com"}),
]

MyApp.Oban.insert_all(jobs)
```

## Job Builder Options

Override worker defaults at enqueue time via options to `new/2`:

```elixir
MyApp.Workers.ProcessData.new(
  %{"data" => "..."},
  queue: :priority,
  priority: 0,
  max_attempts: 5,
  scheduled_at: DateTime.add(DateTime.utc_now(), 3600),
  tags: ["critical", "user_123"],
  meta: %{"user_id" => 123}
)
```

**Common Options:**

- `queue` — Override default queue (atom or string)
- `priority` — Override default priority (0-9)
- `max_attempts` — Override default max attempts
- `scheduled_at` — DateTime for future execution (executes at or after this time)
- `tags` — List of string tags for organization and filtering
- `meta` — Custom map data (separate from job args)
- `unique` — Uniqueness constraints (overrides worker config)
- `replace` — Fields to replace on conflict (requires unique config)

## Transactional Enqueueing

Enqueue jobs within database transactions to ensure atomicity with application changes:

```elixir
Repo.transaction(fn ->
  {:ok, user} = MyApp.Accounts.create_user(params)

  %{"user_id" => user.id}
  |> MyApp.Workers.SendWelcomeEmail.new()
  |> MyApp.Oban.insert()

  {:ok, user}
end)
```

If the transaction rolls back, the job is never inserted. This guarantees no orphaned jobs referencing non-existent data.

## Scheduled Jobs

Schedule jobs for future execution by specifying `scheduled_at`:

```elixir
future = DateTime.add(DateTime.utc_now(), 3600)  # 1 hour from now

%{"event_id" => 1}
|> MyApp.Workers.DispatchEvent.new(scheduled_at: future)
|> MyApp.Oban.insert()
```

Scheduled jobs sit in `:scheduled` state until the scheduled time arrives, then transition to `:available` for processing. The staging process periodically promotes scheduled jobs to available.

## Uniqueness Constraints

Prevent duplicate jobs within a time window using uniqueness options:

```elixir
defmodule MyApp.Workers.UpdateCache do
  use Oban.Worker,
    queue: :cache,
    unique: [
      fields: [:args],
      states: [:scheduled, :available],
      period: 300
    ]
end
```

**Uniqueness Options:**

- `fields` — Which fields to consider for uniqueness: `:args`, `:worker`, `:queue`
- `states` — Which job states to check: `:scheduled`, `:available`, `:executing`, `:retryable`, `:completed`, `:cancelled`, `:discarded`
- `period` — Time window in seconds (default: 3600, one hour)
- `replace` — Fields to update on conflict instead of rejecting

**Example with replace:**

```elixir
%{"user_id" => 42, "data" => "latest"}
|> MyApp.Workers.ProcessUser.new(
  unique: [
    fields: [:args],
    period: 600,
    replace: [:args]
  ]
)
|> MyApp.Oban.insert()
```

If a duplicate job exists within the period, the conflicting job's args are replaced with the new job's args and the job's `scheduled_at` is reset.

## Top-level Configuration

Configure Oban in application config:

```elixir
config :my_app, Oban,
  repo: MyApp.Repo,
  node: :node_1,
  queues: [
    default: 10,
    events: 20,
    batch_processing: 5
  ],
  plugins: [
    {Oban.Plugins.Pruner, interval: :timer.hours(1)}
  ],
  notifier: {Oban.Notifiers.Postgres, []}
```

**Core Configuration:**

- `repo` — Ecto repository module (required)
- `node` — Unique node identifier for distributed setups (default: auto-generated)
- `queues` — Map or keyword list of queue names to concurrency limits
- `plugins` — List of plugin modules with options
- `notifier` — Message bus for notifications (required for distributed features)
- `engine` — Job engine implementation (default: `Oban.Engine.Basic`)
- `prefix` — Database schema prefix (default: `"public"`)
- `testing` — Test mode: `:inline` or `:manual`

## Environment-Specific Configuration

Disable Oban in development/test if desired:

```elixir
# config/dev.exs
config :my_app, Oban, producers: false

# config/test.exs
config :my_app, Oban, testing: :inline
```

## Retrieving Active Configuration

Access Oban's current configuration at runtime:

```elixir
config = Oban.config(MyApp.Oban)
# returns Oban.Config struct with current state
```

Validate configuration before startup:

```elixir
case Oban.Config.validate(my_config) do
  :ok -> IO.puts("Configuration is valid")
  {:error, messages} -> IO.puts(messages)
end
```

---

[← Back to main](oban-2.20.3.md)
**Version:** 2.20.3
