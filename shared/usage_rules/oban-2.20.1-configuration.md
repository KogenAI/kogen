# oban - Configuration & Setup

## Initial Configuration

Add Oban to your supervision tree and configure it with repository and queue settings:

```elixir
# config/config.exs
config :my_app, Oban,
  repo: MyApp.Repo,
  queues: [default: 10, mailers: 5],
  engine: Oban.Engines.Basic
```

## Required Options

- **`:repo`** - Your Ecto repository module (required)
- **`:queues`** - Keyword list mapping queue names to concurrency limits

## Optional Configuration Options

### Database & Performance

```elixir
config :my_app, Oban,
  repo: MyApp.Repo,
  queues: [default: 10],

  # Database schema prefix (for multi-tenant apps)
  prefix: nil,

  # Stage interval: how often to poll for jobs (milliseconds)
  stage_interval: 5000,

  # Dispatch cooldown between execution attempts (milliseconds)
  dispatch_cooldown: 50,

  # Graceful shutdown wait time (seconds)
  shutdown_grace_period: 15
```

### Engine Selection

```elixir
# Basic engine (default, recommended for most cases)
engine: Oban.Engines.Basic

# Inline engine (testing, executes jobs immediately)
engine: Oban.Engines.Inline

# Lite engine (SQLite3 deployments)
engine: Oban.Engines.Lite
```

### Testing Mode

```elixir
# Disable job execution in tests (manual control)
config :my_app, Oban,
  repo: MyApp.Repo,
  queues: [default: 10],
  testing: :manual

# Inline execution in tests (execute jobs immediately)
config :my_app, Oban,
  testing: :inline

# Disabled (default, jobs enqueued but not executed)
config :my_app, Oban,
  testing: :disabled
```

### Logging

```elixir
config :my_app, Oban,
  log: :debug  # Set log level (:debug, :info, :warning, :error)
```

### Plugins

Plugins extend Oban with additional functionality:

```elixir
config :my_app, Oban,
  plugins: [
    {Oban.Plugins.Cron, crons: [
      {"0 2 * * *", MyApp.Workers.DailyReport},
      {"*/5 * * * *", MyApp.Workers.HealthCheck}
    ]}
  ]
```

### Notifier & Peer Configuration

For distributed deployments:

```elixir
config :my_app, Oban,
  notifier: Oban.Notifiers.Postgres,  # or .PG or Phoenix.PubSub
  peer: Oban.Peers.Postgres           # or .PG or .Isolated
```

## Facade Module Pattern

Simplify Oban calls by creating a facade module:

```elixir
defmodule MyApp.Oban do
  use Oban, otp_app: :my_app
end
```

Then use without specifying instance name:

```elixir
# Instead of Oban.insert(Oban, job)
MyApp.Oban.insert(job)

# Instead of Oban.drain_queue(Oban, ...)
MyApp.Oban.drain_queue(queue: :default)
```

## Database Migrations

Oban stores jobs in the `oban_jobs` table. Generate migrations:

```bash
mix ecto.gen.migration create_oban_jobs
```

Then call the generator:

```elixir
defmodule MyApp.Repo.Migrations.CreateObanJobs do
  use Ecto.Migration

  def up do
    Oban.Migrations.up(version: 12)
  end

  def down do
    Oban.Migrations.down(version: 12)
  end
end
```

Run migrations:

```bash
mix ecto.migrate
```

## Distributed Configuration

For multi-node deployments:

```elixir
config :my_app, Oban,
  repo: MyApp.Repo,
  queues: [default: 10],

  # Node identity (must be unique per node)
  node: :my_app@node1,

  # Notifier coordinates jobs across nodes
  notifier: Oban.Notifiers.Postgres,

  # Peer manages leadership elections
  peer: Oban.Peers.Postgres
```

## Engine Configuration

### Basic Engine (Default)

Used in development and production. Supports:

- Job insertion, retrieval, and state transitions
- Standard retry and backoff logic
- Priority-based job fetching

```elixir
config :my_app, Oban,
  engine: Oban.Engines.Basic  # Default
```

### Inline Engine (Testing)

Executes jobs immediately upon insertion:

```elixir
# In test config
config :my_app, Oban,
  engine: Oban.Engines.Inline,
  testing: :inline
```

### Lite Engine (SQLite)

Optimized for SQLite3 deployments:

```elixir
config :my_app, Oban,
  repo: MyApp.Repo,
  engine: Oban.Engines.Lite,
  queues: [default: 10]
```

## Configuration Validation

Create a Config struct to validate options:

```elixir
Oban.Config.new(repo: MyApp.Repo, queues: [default: 10])

# Validate custom configuration
{:ok, config} = Oban.Config.validate([
  repo: MyApp.Repo,
  queues: [default: 10]
])
```

## Supervisor Integration

Add Oban to your application's supervision tree:

```elixir
def start(_type, _args) do
  children = [
    MyApp.Repo,
    {Oban, otp_app: :my_app},
    MyAppWeb.Endpoint
  ]

  Supervisor.start_link(children, strategy: :one_for_one)
end
```

## Custom Instance Names

Run multiple Oban instances in the same application:

```elixir
# Start first instance
{Oban, otp_app: :my_app, name: Oban.Jobs}

# Start second instance with different queues
{Oban, otp_app: :my_app, name: Oban.Tasks}
```

Use with custom names:

```elixir
Oban.insert(Oban.Jobs, job1)
Oban.insert(Oban.Tasks, job2)
```

## Monitoring Configuration Status

Check configuration at runtime:

```elixir
Oban.Registry.config(Oban)
# Returns the Oban.Config struct with all settings
```

---

[← Back to main](oban-2.20.1.md)
**Version:** 2.20.1
