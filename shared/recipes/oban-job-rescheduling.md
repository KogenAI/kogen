# Recipe: Oban Job Rescheduling and Cancellation Patterns

## Problem

When implementing features with scheduled jobs (reminders, notifications, recurring tasks), you often need to:

- Cancel existing jobs when rescheduling events
- Handle entities that may be deleted before job execution
- Implement idempotent job processing
- Query specific jobs by worker type and entity ID
- Use appropriate system-level authorization scopes

## Solution

Implement proper job lifecycle management with cancellation-before-scheduling patterns, defensive job processing, and systematic error handling.

## Implementation

### 1. Job Creation with Scheduled Time

```elixir
defmodule MyApp.Workers.EntityReminderWorker do
  use Oban.Worker, queue: :notifications

  def perform(%Oban.Job{args: %{"entity_id" => entity_id}}) do
    scope = MyApp.Accounts.Scope.system()

    case MyApp.Context.get_entity(scope, entity_id) do
      nil ->
        # Entity was deleted - job can complete successfully
        {:ok, :entity_not_found}

      entity ->
        # Check if entity is still in a state that requires notification
        if entity.status == :cancelled do
          {:ok, :entity_cancelled}
        else
          MyApp.Notifier.deliver_reminder(entity)
        end
    end
  end
end
```

### 2. Scheduling Jobs with Cancellation

```elixir
defp schedule_reminder(entity) do
  # Calculate when to send the reminder
  scheduled_time = calculate_reminder_time(entity)

  # Create and enqueue the job
  %{entity_id: entity.id}
  |> EntityReminderWorker.new(scheduled_at: scheduled_time)
  |> Oban.insert()
end

defp reschedule_reminder(entity) do
  # CRITICAL: Cancel existing jobs first
  cancel_reminder(entity)

  # Then schedule new one
  schedule_reminder(entity)
end

defp cancel_reminder(entity) do
  # Query for pending jobs for this entity
  query =
    from(
      j in Oban.Job,
      where: j.worker == "MyApp.Workers.EntityReminderWorker",
      where: fragment("?->>'entity_id' = ?", j.args, ^entity.id),
      where: j.state in ["available", "scheduled", "executing"]
    )

  # Cancel all matching jobs
  Oban.cancel_all_jobs(query)
end

defp calculate_reminder_time(entity) do
  DateTime.add(entity.scheduled_at, -entity.reminder_minutes_before, :minute)
end
```

### 3. Context Integration Pattern

```elixir
def update_entity(scope, entity, attrs) do
  case get_entity(scope, entity.id) do
    nil ->
      {:error, :unauthorized}

    entity ->
      result =
        entity
        |> Entity.changeset(attrs)
        |> Repo.update()

      case result do
        {:ok, updated_entity} ->
          # Reschedule any associated jobs
          reschedule_reminder(updated_entity)
          broadcast_entity_event(:updated, updated_entity)
          {:ok, updated_entity}

        error ->
          error
      end
  end
end

def cancel_entity(scope, entity, reason) do
  case get_entity(scope, entity.id) do
    nil ->
      {:error, :unauthorized}

    entity ->
      result =
        entity
        |> Entity.cancel_changeset(%{cancellation_reason: reason})
        |> Repo.update()

      case result do
        {:ok, cancelled_entity} ->
          # Cancel associated jobs
          cancel_reminder(cancelled_entity)
          broadcast_entity_event(:cancelled, cancelled_entity)
          {:ok, cancelled_entity}

        error ->
          error
      end
  end
end
```

### 4. System Scope for Background Operations

```elixir
# In your worker
def perform(%Oban.Job{args: %{"entity_id" => entity_id}}) do
  # IMPORTANT: Use system scope for background operations
  scope = MyApp.Accounts.Scope.system()

  # Never use user/company scopes in workers
  # This would fail: scope = %Scope{user: user, company: company}

  case MyApp.Context.get_entity(scope, entity_id) do
    nil -> {:ok, :entity_not_found}
    entity -> process_entity(entity)
  end
end
```

### 5. Advanced Job Querying

```elixir
def list_pending_reminders_for_entity(entity_id) do
  from(
    j in Oban.Job,
    where: j.worker == "MyApp.Workers.EntityReminderWorker",
    where: fragment("?->>'entity_id' = ?", j.args, ^entity_id),
    where: j.state in ["available", "scheduled"],
    order_by: [asc: j.scheduled_at]
  )
  |> Repo.all()
end

def cancel_all_reminders_for_user(user_id) do
  # More complex query - cancel jobs for all entities belonging to a user
  subquery =
    from e in Entity,
      where: e.user_id == ^user_id,
      select: e.id

  query =
    from(
      j in Oban.Job,
      where: j.worker == "MyApp.Workers.EntityReminderWorker",
      where: fragment("(?->>'entity_id')::uuid", j.args) in subquery(subquery),
      where: j.state in ["available", "scheduled", "executing"]
    )

  Oban.cancel_all_jobs(query)
end
```

### 6. Bulk Rescheduling Pattern

```elixir
def bulk_reschedule_reminders(entities) do
  # Cancel all existing jobs first
  entity_ids = Enum.map(entities, & &1.id)

  query =
    from(
      j in Oban.Job,
      where: j.worker == "MyApp.Workers.EntityReminderWorker",
      where: fragment("(?->>'entity_id')::uuid", j.args) in ^entity_ids,
      where: j.state in ["available", "scheduled", "executing"]
    )

  Oban.cancel_all_jobs(query)

  # Then schedule new jobs
  Enum.each(entities, &schedule_reminder/1)
end
```

## Considerations

### When to Use This Pattern

- Scheduled notifications/reminders that can be rescheduled
- Jobs tied to mutable entities (interviews, appointments, deadlines)
- Background processing that needs to respect entity lifecycle
- Multi-tenant applications requiring proper authorization

### When NOT to Use This Pattern

- Fire-and-forget jobs that don't need cancellation
- Jobs processing immutable data
- Simple queue-based processing without scheduling

### Performance Considerations

- **Job Queries**: Fragment queries on JSONB are indexed in Oban but still slower than regular columns
- **Batch Operations**: Use `cancel_all_jobs/1` instead of individual cancellations
- **Job Cleanup**: Oban automatically cleans completed jobs, but cancelled jobs may accumulate

### Important Pitfalls

- **Race Conditions**: Always cancel before scheduling to avoid duplicate jobs
- **Authorization**: Use `Scope.system()` in workers, never user/company scopes
- **Entity State**: Check entity status in worker before processing
- **Job Arguments**: Use string keys in args (not atoms) for JSONB queries
- **Fragment Syntax**: Cast JSONB to proper types when querying (`(?->>'id')::uuid`)
- **Worker Module Names**: Use full module names in queries ("MyApp.Workers.Worker")

## Example Usage

From interview scheduling where reminder jobs need to be rescheduled when interview times change:

```elixir
# When interview is updated
case Scheduling.update_interview(scope, interview, params) do
  {:ok, updated_interview} ->
    # Worker automatically reschedules reminder
    {:noreply, handle_success(socket, updated_interview)}

  {:error, changeset} ->
    {:noreply, assign_form(socket, changeset)}
end
```

## Related Recipes

- Database migration patterns - For job queue table optimizations
- Phoenix testing patterns - For testing background job functionality
