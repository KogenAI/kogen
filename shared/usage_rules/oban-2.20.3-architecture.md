# oban - System Architecture & Notifiers

## Supervision Tree Architecture

Oban's supervision tree organizes multiple components for distributed job processing:

```
Oban Supervisor
├── Notifier (Postgres, PG, or Phoenix)
├── Peer (Leadership election)
├── Each Queue Supervisor
│   ├── Producer (fetches & dispatches jobs)
│   ├── Job Executor (runs jobs)
│   └── Queue State Manager
└── Plugins (Pruner, Cron, etc.)
```

Each queue runs independently with its own concurrency limit, allowing fine-grained resource allocation across different job types.

## Notifiers & Message Coordination

The notifier coordinates queue state and job management across nodes. Oban provides three notifier implementations:

**Postgres Notifier** — Uses PostgreSQL LISTEN/NOTIFY:

```elixir
config :my_app, Oban,
  notifier: {Oban.Notifiers.Postgres, []}
```

Most common choice for PostgreSQL deployments. Uses database-level pub/sub for reliable coordination.

**PG Notifier** — Uses Distributed Erlang:

```elixir
config :my_app, Oban,
  notifier: {Oban.Notifiers.PG, []}
```

Suitable for Erlang clusters without external coordination systems. Requires Erlang networking to be configured.

**Phoenix Notifier** — Leverages Phoenix.PubSub:

```elixir
config :my_app, Oban,
  notifier: {Oban.Notifiers.Phoenix, [pubsub: MyApp.PubSub]}
```

Integrates with your Phoenix application's pub/sub system. Enables custom transport adapters (Redis, RabbitMQ, etc.).

## Notifier Channels

Oban uses four internal channels for coordination:

1. **insert** — Job insertion signals. Queue producers listen here to dispatch newly added work. Firing this channel wakes idle producers.

2. **leader** — Node leadership election messages. Used for distributed coordination and task scheduling across nodes.

3. **signal** — Action instructions for queue operations (pause, resume, scale, cancel). Commands from `pause_queue/2`, `scale_queue/2`, etc. broadcast here.

4. **sonar** — Health check messages monitoring pub/sub connectivity. Tests whether the notifier can reliably deliver messages.

## Notifier Functions

**listen()** — Register current process for notifications:

```elixir
Oban.Notifier.listen(MyApp.Oban, [:insert, :signal])
```

Process receives `{:notification, channel, payload}` messages matching subscribed channels.

**notify()** — Broadcast notification to all subscribers:

```elixir
Oban.Notifier.notify(MyApp.Oban, :insert, %{queue: "default"})
```

Message propagates to all nodes with connected notifiers.

**status()** — Get notifier connectivity status:

```elixir
case Oban.Notifier.status(MyApp.Oban) do
  :clustered -> "Multi-node communication working"
  :solitary -> "Single node or Erlang cluster issue"
  :isolated -> "Cannot receive external messages"
  :unknown -> "Status unknown"
end
```

**unlisten()** — Unsubscribe from channels:

```elixir
Oban.Notifier.unlisten(MyApp.Oban, [:insert])
```

## Connectivity Status Meanings

- **`:clustered`** — Multi-node deployment with successful inter-node communication. Queue operations propagate across all nodes.

- **`:solitary`** — Single-node deployment or Erlang cluster configured but nodes cannot communicate. Operations work locally only.

- **`:isolated`** — Notifier cannot receive external messages, preventing queue control operations. Check notifier configuration and network connectivity.

- **`:unknown`** — Connectivity status has not been determined yet. May indicate startup phase.

## Leader Election & Peer Coordination

Oban uses peer leadership election for distributed deployments. One node is elected leader and performs housekeeping tasks (job rescue, staging).

**Default Peer** — Erlang-based leadership:

```elixir
config :my_app, Oban,
  peer: Oban.Peers.Postgres  # or Oban.Peers.PG
```

Leadership is negotiated via the notifier. Ensure notifier is operational for peer coordination to function.

## Plugins

Plugins extend Oban functionality. Configure in application setup:

```elixir
config :my_app, Oban,
  plugins: [
    {Oban.Plugins.Pruner, interval: :timer.hours(1), retention: :timer.days(7)},
    {Oban.Plugins.Cron, crontab: [
      {"0 0 * * *", MyApp.Workers.DailyReport},
      {"*/5 * * * *", MyApp.Workers.PollExternal}
    ]}
  ]
```

**Built-in Plugins:**

- **Pruner** — Deletes old completed/cancelled/discarded jobs after retention period
- **Cron** — Enqueues jobs on recurring schedules (CRON patterns)
- **Repeater** — Re-enqueues completed jobs at intervals
- **Stager** — Promotes scheduled jobs to available state
- **Notifier** — Manages pub/sub connectivity

Oban Pro includes additional plugins like Smart Engine and Workflow support.

## Configuration Reference

**Core Options:**

- `repo` — Ecto repository (required)
- `engine` — Job engine (default: Oban.Engine.Basic)
- `notifier` — Message bus (required for distributed features)
- `node` — Unique node identifier (default: auto-generated)
- `prefix` — Database schema prefix (default: "public")
- `testing` — Test mode: `:inline` or `:manual`
- `log` — Log level for Oban's internal logging

**Queue Configuration:**

- `queues` — Map or keyword list of queue names and concurrency limits
- `partition_size` — Jobs per database query
- `stage_interval` — Milliseconds between staging runs (default: 5000)
- `dispatch_cooldown` — Milliseconds before producer dispatch (default: 100)
- `shutdown_grace_period` — Milliseconds to wait for executing jobs (default: 15000)

**Advanced:**

- `get_dynamic_repo` — Function returning repo at runtime
- `insert_trigger` — Custom trigger for new job notifications
- `plugins` — List of plugin modules with configuration

## Distributed Deployment Checklist

When deploying Oban across multiple nodes:

1. ✓ Configure notifier (Postgres, PG, or Phoenix)
2. ✓ Ensure notifier is accessible from all nodes
3. ✓ Configure unique node identifiers
4. ✓ Verify database connectivity from all nodes
5. ✓ Test queue operations across nodes (pause, resume, scale)
6. ✓ Monitor notifier status via telemetry
7. ✓ Configure graceful shutdown on all nodes
8. ✓ Set up metrics collection for job throughput and errors

---

[← Back to main](oban-2.20.3.md)
**Version:** 2.20.3
