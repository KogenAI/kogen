# oban

Oban is a robust background job processing framework for Elixir applications built on PostgreSQL, MySQL, or SQLite3 for job persistence. It emphasizes reliability, consistency, and observability while retaining job data indefinitely for historic metrics and inspection. Unlike competing solutions, Oban stores jobs directly in your existing database with atomic transactional guarantees, eliminating external dependencies and simplifying backups. The framework supports isolated queues with independent scaling, runtime queue control, job management including cancellation and retry, scheduling for future execution and CRON patterns, uniqueness enforcement, ten-tier priority levels, and comprehensive telemetry integration.

Oban operates as a production-ready system that requires Elixir 1.15+, Erlang 24+, and one of PostgreSQL 14.0+, MySQL 8.4+, or SQLite3 3.37.0+. The core design principle ensures reliability by leveraging your database as the single source of truth, providing transactional safety for enqueueing jobs alongside application data changes, and enabling job data persistence with application backups. Advanced features like global concurrency control, workflow composition, and batch processing are available through Oban Pro.

## Quick Start

Installation via mix.exs:

```elixir
def deps do
  [
    {:oban, "~> 2.20"}
  ]
end
```

Configure in `config/config.exs`:

```elixir
config :my_app, Oban,
  repo: MyApp.Repo,
  queues: [default: 10, events: 20]
```

Define a worker:

```elixir
defmodule MyApp.Workers.SendEmail do
  use Oban.Worker, queue: :mailers

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"email" => email}}) do
    # send email
    :ok
  end
end
```

Enqueue a job:

```elixir
%{"email" => "user@example.com"}
|> MyApp.Workers.SendEmail.new()
|> MyApp.Oban.insert()
```

Include Oban in your supervision tree:

```elixir
def start(_type, _args) do
  children = [
    MyApp.Repo,
    {Oban, Application.fetch_env!(:my_app, Oban)},
    # other children...
  ]

  Supervisor.start_link(children, strategy: :one_for_one)
end
```

## Documentation Sections

- [Job Definition & Worker Callbacks](oban-2.20.3-job-definition.md)
- [Job Enqueueing & Configuration](oban-2.20.3-job-enqueueing.md)
- [Queue Management & Runtime Control](oban-2.20.3-queue-management.md)
- [Job Execution & Error Handling](oban-2.20.3-job-execution.md)
- [Testing Patterns & Utilities](oban-2.20.3-testing.md)
- [Observability & Telemetry](oban-2.20.3-telemetry.md)
- [Database Engines & Persistence](oban-2.20.3-engines.md)
- [System Architecture & Notifiers](oban-2.20.3-architecture.md)

---

**Version:** 2.20.3
**Source:** [hexdocs.pm/oban](https://hexdocs.pm/oban/)
**Generated:** 2026-04-25
