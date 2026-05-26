# oban

Oban is a robust, reliable background job processing framework for Elixir that leverages PostgreSQL, MySQL, or SQLite3 for data persistence. The framework emphasizes three primary goals: reliability, consistency, and observability. Unlike traditional job queues that discard job history, Oban retains job data indefinitely for historic metrics and inspection, allowing applications to run without losing orphaned jobs.

Oban minimizes system dependencies by using your existing SQL database, enables transactional control (enqueue jobs atomically with other database changes), and backs up jobs alongside your application data. It provides isolated queues and jobs with independent concurrency management, runtime queue control, job cancellation, unique job enforcement, scheduled and CRON-style periodic execution, priority levels, and graceful shutdown with configurable grace periods.

Oban Pro extends the core framework with advanced features including workflows, decorators, job chains, structured jobs, worker hooks, global concurrency limits, queue partitioning, and dynamic queues—but the open-source version covers most production use cases.

## Quick Start

### Installation

Add Oban to your `mix.exs`:

```elixir
def deps do
  [
    {:oban, "~> 2.20"}
  ]
end
```

### Basic Configuration

Configure Oban in your `config/config.exs`:

```elixir
config :my_app, Oban,
  repo: MyApp.Repo,
  queues: [default: 10, mailers: 5]
```

Add to your supervision tree:

```elixir
def start(_type, _args) do
  children = [
    MyApp.Repo,
    {Oban, otp_app: :my_app}
  ]
  Supervisor.start_link(children, strategy: :one_for_one)
end
```

### Define a Worker

```elixir
defmodule MyApp.Workers.ProcessEmail do
  use Oban.Worker, queue: :mailers, max_attempts: 3

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"email" => email}}) do
    :ok = Email.send(email)
    :ok
  end
end
```

### Enqueue a Job

```elixir
%{"email" => "user@example.com"}
|> MyApp.Workers.ProcessEmail.new()
|> Oban.insert()
```

## Documentation Sections

- [Workers & Job Execution](oban-2.20.1-workers.md) - Creating workers, handling results, retries, backoff, timeouts
- [Job Configuration & Options](oban-2.20.1-jobs.md) - Job structure, scheduling, uniqueness, priorities
- [Queue Management](oban-2.20.1-queues.md) - Queue setup, runtime operations, monitoring
- [Configuration & Setup](oban-2.20.1-configuration.md) - System configuration, database engines, plugins
- [Testing & Assertions](oban-2.20.1-testing.md) - Test utilities, job assertions, testing modes
- [Telemetry & Monitoring](oban-2.20.1-telemetry.md) - Event emission, custom handlers, observability
- [Distributed Operations](oban-2.20.1-distributed.md) - Notifiers, peer coordination, multi-node setups
- [Advanced Patterns](oban-2.20.1-advanced.md) - Job cancellation, registry, plugins, engines

---

**Version:** 2.20.1
**Source:** [hexdocs.pm/oban](https://hexdocs.pm/oban/)
**Generated:** 2025-10-28
