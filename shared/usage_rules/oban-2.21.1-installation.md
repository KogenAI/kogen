# oban - Installation & Configuration

## System Requirements

- Elixir 1.15+
- Erlang 24+
- PostgreSQL 14.0+, MySQL 8.4+, or SQLite3 3.37.0+

## Basic Configuration

Configure Oban in your application's config files with the required `repo` and desired `queues`:

```elixir
# config/config.exs
config :my_app, Oban,
  repo: MyApp.Repo,
  queues: [
    default: 10,      # 10 concurrent jobs
    mailers: 20,      # 20 concurrent email jobs
    events: 5         # 5 concurrent event jobs
  ]
```

## Core Configuration Options

**`repo`** (required) — Your Ecto repository module handling database operations.

**`queues`** (required) — Keyword list mapping queue names to concurrency limits. Each queue executes jobs independently with its own process and concurrency control.

**`name`** — Oban instance identifier. Defaults to `:default` for single-instance setups.

**`node`** — Explicitly set the node identifier. Useful for distributed deployments.

**`engine`** — Backend engine for job execution. Defaults to PostgreSQL engine.

**`notifier`** — Notification system for cross-node coordination. Options include:

- `Oban.Notifiers.Postgres` (uses LISTEN/NOTIFY)
- `Oban.Notifiers.PG` (uses Distributed Erlang process groups)
- `Oban.Notifiers.Phoenix` (uses Phoenix.PubSub)

**`peer`** — Enables node leadership and coordination. Set to `false` for web-only nodes to prevent leadership.

**`plugins`** — List of plugin modules for extended functionality (e.g., Lifeline plugin for orphaned job recovery).

**`log`** — Logger level (`:debug`, `:info`, etc.) or `false` to disable logging.

**`prefix`** — Database schema prefix for isolating Oban tables.

**`testing`** — Test mode configuration:

- `:disabled` (default) — Normal production behavior
- `:inline` — Jobs execute immediately in the calling process without database writes
- `:manual` — Jobs insert to database for explicit test execution

**`shutdown_grace_period`** — Milliseconds to wait for executing jobs to finish during shutdown. Default: 15000. Increase if jobs frequently timeout.

**`stage_interval`** — Millisecond timeout for job staging operations.

**`dispatch_cooldown`** — Cooldown period between dispatches to prevent excessive database polling.

## Testing Configuration

For development and test environments, enable inline testing mode to prevent database overhead:

```elixir
# config/test.exs
config :my_app, Oban, testing: :inline
```

For more complex test scenarios requiring database verification:

```elixir
config :my_app, Oban, testing: :manual
```

## Multi-Node Deployments

In distributed setups, configure each node appropriately:

```elixir
# Web-only node (no job processing)
config :my_app, Oban,
  peer: false,  # Disable leadership
  queues: []    # No queues

# Worker node
config :my_app, Oban,
  peer: true,   # Enable leadership
  queues: [default: 10]
```

## Validation

Before deployment, validate configuration using `Oban.Config.validate/1`:

```elixir
iex> Oban.Config.validate(repo: MyApp.Repo, queues: [default: 10])
:ok
```

---

[← Back to main](oban-2.21.1.md)  
**Version:** 2.21.1
