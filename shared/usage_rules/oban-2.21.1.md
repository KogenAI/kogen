# oban

Oban is a robust background job framework for Elixir built on PostgreSQL, MySQL, or SQLite3 that prioritizes reliability, consistency, and observability. Unlike other job queue systems, Oban retains all job data for historic metrics and inspection, ensuring jobs are never lost or orphaned. The framework uses your existing SQL database as the persistence layer, reducing system complexity while providing transactional safety for atomic job enqueuing alongside other database operations.

## Quick Start

```elixir
# In config/config.exs
config :my_app, Oban,
  repo: MyApp.Repo,
  queues: [mailers: 20, events: 10]

# Define a worker
defmodule MyApp.MailerWorker do
  use Oban.Worker, queue: :mailers

  def perform(%Oban.Job{args: %{"email" => email}}) do
    Email.deliver(email)
    :ok
  end
end

# Enqueue a job
%{email: "user@example.com"}
|> MyApp.MailerWorker.new()
|> Oban.insert()
```

## Documentation Sections

- [Installation & Configuration](oban-2.21.1-installation.md)
- [Workers & Job Execution](oban-2.21.1-workers.md)
- [Job Management & Lifecycle](oban-2.21.1-jobs.md)
- [Queue Management & Control](oban-2.21.1-queues.md)
- [Scheduling & CRON Jobs](oban-2.21.1-scheduling.md)
- [Testing Patterns & Helpers](oban-2.21.1-testing.md)
- [Monitoring, Telemetry & Troubleshooting](oban-2.21.1-monitoring.md)
- [Advanced Topics & Pro Features](oban-2.21.1-advanced.md)

---

**Version:** 2.21.1  
**Source:** [hexdocs.pm/oban](https://hexdocs.pm/oban/)  
**Generated:** 2026-04-25
