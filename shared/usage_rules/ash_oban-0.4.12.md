# ash_oban

Ash Oban integrates Oban job processing with Ash resources, enabling scheduled actions and triggers that automatically execute resource actions based on defined conditions. This library provides two core primitives: triggers (for record-specific operations on schedules) and scheduled actions (for generic operations on fixed schedules).

## Quick Start

### Installation

Add to `mix.exs`:

```elixir
{:ash_oban, "~> 0.4.12"}
```

### Setup with Igniter (Recommended)

```bash
mix igniter.install ash_oban
```

This automatically installs Oban alongside Ash Oban.

### Manual Setup

Update your Application module:

```elixir
{Oban, AshOban.config(Application.fetch_env!(:my_app, :ash_domains), your_oban_config)}
```

### Enable on Resources

```elixir
defmodule MyApp.Resource do
  use Ash.Resource, domain: MyDomain, extensions: [AshOban]
end
```

## Core Concepts

### Triggers

Triggers execute resource actions periodically for records matching specific conditions. Each matching record receives its own independent job.

**When to use triggers:**

- Processing records that meet changing criteria
- Handling subscription expirations
- Sending periodic notifications
- Cleanup operations on filtered datasets

**Key benefits:**

- Granular error handling—individual record failures don't cascade
- Queryable execution state
- Easy manual re-triggering via state reset
- Natural fit with domain model

### Scheduled Actions

Scheduled actions run generic operations on fixed schedules, independent of record conditions.

**When to use scheduled actions:**

- Importing data from external services
- Running maintenance tasks
- Bulk operations without per-record state tracking
- Simple periodic jobs

## Configuration

### Trigger Configuration

Define triggers in the `oban do` DSL block:

```elixir
oban do
  triggers do
    trigger :process do
      action :process
      where expr(processed != true)
      scheduler_cron "* * * * *"
      on_error :errored
    end
  end
end
```

**Core Options:**

- `action` - The Ash action to execute
- `where` - Filter expression determining which records to process
- `scheduler_cron` - Cron schedule (supports shortcuts like `@daily`, `@hourly`)
- `on_error` - Update action to call if trigger fails (receives `:error` argument)
- `read_action` - Custom read action (defaults to `:read`)

**Queue Naming:** Default queue is `:resource_shortname_triggername` (e.g., `:post_publish` for Post resource with `:publish` trigger).

### Scheduled Action Configuration

```elixir
schedule :import_from_github, "0 */6 * * *" do
  worker_module_name AshOban.Test.Triggered.AshOban.ActionWorker
end
```

## Best Practices

### Error Handling

Attach `on_error` actions to gracefully manage trigger failures:

```elixir
trigger :send_notification do
  action :send_notification
  where expr(should_notify == true)
  scheduler_cron "@daily"
  on_error :handle_notification_error
end
```

Keep error handlers simple to prevent cascading failures. The error is passed via an `:error` argument.

### Authorization

By default, `authorize?: true` is passed to trigger actions. Bypass authorization by:

1. Adding a policy bypass for `AshOban.Checks.AshObanInteraction`
2. Setting `config :ash_oban, authorize?: false` globally

### Actor Persistence

Preserve user context across scheduled jobs using an ActorPersister:

```elixir
defmodule MyApp.AshObanActorPersister do
  use AshOban.ActorPersister

  def store(%MyApp.User{id: id}), do: %{"type" => "user", "id" => id}
  def lookup(%{"type" => "user", "id" => id}), do: MyApp.Accounts.get_user_by_id(id)
  def lookup(nil), do: {:ok, nil}
end
```

Configure: `config :ash_oban, :actor_persister, MyApp.AshObanActorPersister`

### Eligibility Tracking

Use calculations to define complex eligibility criteria:

```elixir
calculations do
  calculate :should_process, :boolean do
    expr(processed != true and days_old > 7)
  end
end

oban do
  triggers do
    trigger :process do
      action :process
      where expr(should_process == true)
      scheduler_cron "@daily"
    end
  end
end
```

### State Management

Track action execution in attributes to avoid reprocessing:

```elixir
attributes do
  attribute :processed, :boolean, default: false
  attribute :last_processed_at, :datetime
end

oban do
  triggers do
    trigger :process do
      action :process
      where expr(processed == false)
      scheduler_cron "@hourly"
    end
  end
end
```

### Oban Pro Considerations

If using Oban Pro:

- Set `config :ash_oban, :pro?, true`
- Use `state :paused` or `state :deleted` rather than deleting triggers to prevent orphaned cron jobs
- Actor records may be deleted/modified between scheduling and execution—design handlers defensively

### Transaction Safety

Each triggered record executes within explicit database transactions. Design actions to be idempotent and transaction-safe.

### Cron Syntax

Supported shortcuts: `@yearly`, `@monthly`, `@weekly`, `@daily`, `@midnight`, `@hourly`

Standard cron format: `"minute hour day month weekday"`

---

**Version:** 0.4.12
**Source:** [hexdocs.pm/ash_oban](https://hexdocs.pm/ash_oban/)
**Generated:** 2025-10-28
